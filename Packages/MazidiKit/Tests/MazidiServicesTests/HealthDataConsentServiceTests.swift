import Foundation
import Testing
@testable import MazidiServices
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiSync

private let notice = PrivacyNoticeVersion("v1")
private let notice2 = PrivacyNoticeVersion("v2")

private func makeService(
    store: InMemorySyncStore,
    clock: FixedClock = FixedClock(),
    actorID: UUID = UUID()
) -> HealthDataConsentService {
    HealthDataConsentService(
        store: .init(consent: store, operations: store),
        clock: clock,
        actorID: actorID
    )
}

@Suite struct HealthDataConsentServiceTests {
    // MARK: - The gate

    @Test func gateIsClosedBeforeAnyDecision() async throws {
        let service = makeService(store: InMemorySyncStore())
        for purpose in HealthDataConsent.Purpose.allCases {
            #expect(try await service.mayCollect(purpose) == false)
            #expect(try await service.decision(for: purpose) == .neverGranted)
        }
    }

    @Test func gateOpensOnlyForTheGrantedPurposes() async throws {
        let clock = FixedClock()
        let service = makeService(store: InMemorySyncStore(), clock: clock)

        try await service.grant([.performanceRecording], noticeVersion: notice)

        #expect(try await service.mayCollect(.performanceRecording))
        #expect(try await service.mayCollect(.perceivedExertionRecording) == false)
        #expect(try await service.mayCollect(.coachSharing) == false)
        #expect(try await service.decision(for: .performanceRecording)
                == .permitted(noticeVersion: notice, grantedAt: clock.now()))
    }

    @Test func gateClosesAgainForAWithdrawnPurposeOnly() async throws {
        let clock = FixedClock()
        let service = makeService(store: InMemorySyncStore(), clock: clock)
        try await service.grant(HealthDataConsent.Purpose.allCases, noticeVersion: notice)

        clock.advance(by: 60)
        try await service.withdraw(.coachSharing)

        #expect(try await service.mayCollect(.coachSharing) == false)
        #expect(try await service.decision(for: .coachSharing) == .withdrawn(at: clock.now()))
        #expect(try await service.mayCollect(.performanceRecording))       // unbundled
        #expect(try await service.mayCollect(.perceivedExertionRecording))
    }

    @Test func gateSurvivesAServiceRestartBecauseItReadsTheDurableLedger() async throws {
        let store = InMemorySyncStore()
        do {
            let service = makeService(store: store)
            try await service.grant([.coachSharing], noticeVersion: notice)
        }
        let restarted = makeService(store: store)
        #expect(try await restarted.mayCollect(.coachSharing))
        #expect(try await restarted.mayCollect(.performanceRecording) == false)
    }

    // MARK: - Grant / withdraw / re-grant

    @Test func grantingSeveralPurposesRecordsSeveralIndependentDecisions() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)

        try await service.grant([.performanceRecording, .coachSharing], noticeVersion: notice)

        let records = try await service.ledger().records
        #expect(records.count == 2)                                 // not one bundled agreement
        #expect(Set(records.map(\.purpose)) == [.performanceRecording, .coachSharing])
        #expect(Set(records.map(\.id)).count == 2)                  // distinct records
        // Each has its own outbox operation on its own aggregate.
        for record in records {
            let ops = try await store.operations(inAggregate: record.id.rawValue)
            #expect(ops.map(\.kind) == [.healthDataConsentGranted])
        }
    }

    @Test func aPurposeNotPassedIsNeverGranted() async throws {
        let service = makeService(store: InMemorySyncStore())
        try await service.grant([.performanceRecording], noticeVersion: notice)
        // Silence is never consent.
        #expect(try await service.decision(for: .perceivedExertionRecording) == .neverGranted)
        #expect(try await service.ledger().records.count == 1)
    }

    @Test func reGrantingAnAlreadyGrantedPurposeIsAnIdempotentNoOp() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        try await service.grant([.coachSharing], noticeVersion: notice)
        try await service.grant([.coachSharing], noticeVersion: notice)

        #expect(try await service.ledger().records.count == 1)      // no duplicate in-force record
        #expect(try await store.pendingOperations().count == 1)
    }

    @Test func withdrawalThenReGrantAppendsANewRecordAndKeepsTheOldOne() async throws {
        let clock = FixedClock()
        let service = makeService(store: InMemorySyncStore(), clock: clock)
        try await service.grant([.coachSharing], noticeVersion: notice)
        let firstID = try await service.ledger().records[0].id

        clock.advance(by: 60)
        try await service.withdraw(.coachSharing)
        clock.advance(by: 60)
        try await service.grant([.coachSharing], noticeVersion: notice2)

        let records = try await service.ledger().history(for: .coachSharing)
        #expect(records.count == 2)
        #expect(records[0].id == firstID)
        #expect(records[0].withdrawnAt != nil)                       // history kept
        #expect(records[1].noticeVersion == notice2)                 // consent to the current wording
        #expect(try await service.mayCollect(.coachSharing))
    }

    @Test func withdrawingSomethingNotInForceIsRefusedAndChangesNothing() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        await #expect(throws: HealthDataConsentError.noConsentInForce(.coachSharing)) {
            try await service.withdraw(.coachSharing)
        }
        #expect(try await service.ledger().records.isEmpty)
        #expect(try await store.pendingOperations().isEmpty)
    }

    // MARK: - Outbox

    @Test func everyDecisionIsQueuedForSyncInOrderPerRecord() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        try await service.grant([.performanceRecording], noticeVersion: notice)
        try await service.withdraw(.performanceRecording)

        let recordID = try await service.ledger().records[0].id
        let ops = try await store.operations(inAggregate: recordID.rawValue)
        #expect(ops.map(\.kind) == [.healthDataConsentGranted, .healthDataConsentWithdrawn])
        #expect(ops.map(\.sequence) == [0, 1])
        #expect(ops.allSatisfy { $0.entityType == .healthDataConsent })
        #expect(Set(ops.map(\.idempotencyKey)).count == 2)
    }

    @Test func syncPayloadCarriesOnlyTheConsentRecord() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        try await service.grant([.perceivedExertionRecording], noticeVersion: notice)

        let op = try #require(try await store.pendingOperations().first)
        let decoded = try JSONDecoder().decode(HealthDataConsent.self, from: op.payload)
        #expect(decoded.purpose == .perceivedExertionRecording)
        #expect(decoded.noticeVersion == notice)
        // The payload is exactly the record — no session, no set, no measurement rides along.
        #expect(decoded == (try await service.ledger().records[0]))
    }

    // MARK: - Audit (ids and purpose identifiers only)

    @Test func auditEventsCarryIdsAndPurposeIdentifiersOnly() async throws {
        let store = InMemorySyncStore()
        let actorID = UUID()
        let service = makeService(store: store, actorID: actorID)
        try await service.grant([.coachSharing], noticeVersion: notice)
        try await service.withdraw(.coachSharing)

        let record = try await service.ledger().records[0]
        let events = try await store.allEvents()
        #expect(events.map(\.kind) == [.healthDataConsentGranted, .healthDataConsentWithdrawn])
        for event in events {
            #expect(event.actorID == actorID)
            #expect(event.subjectDescription == "healthDataConsent:\(record.id)")
            #expect(event.payload == ["purpose": "coachSharing", "noticeVersion": "v1"])
            // Every value is an id, a purpose name or a wording version — nothing free-form.
            #expect(!event.subjectDescription.contains("rpe"))
            #expect(event.payload.values.allSatisfy { !$0.isEmpty })
        }
        // Hash chain intact across both events.
        #expect(events[1].previousHash == auditChainHash(of: events[0]))
    }

    @Test func auditIsWrittenInTheSameWriteAsTheConsentRecord() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        await store.setFailNextAtomicWrite(true)

        await #expect(throws: (any Error).self) {
            try await service.grant([.coachSharing], noticeVersion: notice)
        }
        // Neither half landed: no record, no operation, no audit event.
        #expect(try await store.consentLedger().records.isEmpty)
        #expect(try await store.pendingOperations().isEmpty)
        #expect(try await store.allEvents().isEmpty)
    }
}
