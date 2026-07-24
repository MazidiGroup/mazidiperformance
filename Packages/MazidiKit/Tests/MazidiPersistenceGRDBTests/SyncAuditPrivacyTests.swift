import Foundation
import Testing
import MazidiAuth
import MazidiDomain
import MazidiFoundations
import MazidiNetworking
import MazidiSync
@testable import MazidiPersistenceGRDB

/// ADR-0006/ADR-0012 privacy exclusions: sync audit subjects and mutation envelopes carry
/// IDS ONLY — never tokens, credentials, signed URLs, full notes, or private message bodies;
/// user-facing errors expose no server internals.
@Suite struct SyncAuditPrivacyTests {
    private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

    private func assignment(notes: String) throws -> WorkoutAssignment {
        var template = WorkoutTemplate(
            draft: WorkoutTemplateContent(title: "Lower A", exercises: [
                PrescribedExercise(slug: "barbell-squat", order: 0,
                                   prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80),
                                   coachNotes: notes),
            ]),
            updatedAt: t0
        )
        let version = try template.publish(at: t0)
        return WorkoutAssignment(version: version, assigneeAccountRef: "dev-client-001", assignedAt: t0)
    }

    // The assignmentDelivered audit subject is an id only — no coach notes / content leak.
    @Test func deliveredAuditSubjectIsIdOnlyNeverContent() async throws {
        let store = try GRDBStore.inMemory()
        let secretNote = "SECRET client medical note do-not-leak"
        let a = try assignment(notes: secretNote)
        try await store.saveAssignmentAtomically(a, enqueueing: [])
        try await store.advanceAssignmentDelivery(id: a.id, to: .queuedForUpload, at: t0, auditActorID: UUID())
        try await store.advanceAssignmentDelivery(id: a.id, to: .acceptedByServer, at: t0, auditActorID: UUID())

        let events = try await store.allEvents().filter { $0.kind == .assignmentDelivered }
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.subjectDescription == "assignment:\(a.id.rawValue.uuidString)")
        // No content leaks into the audit record anywhere.
        #expect(!event.subjectDescription.contains(secretNote))
        #expect(event.payload.values.allSatisfy { !$0.contains(secretNote) })
    }

    // A mutation envelope for an assignment carries the opaque payload + ids, but never a
    // token/credential, and the payload is the domain snapshot (no auth material).
    @Test func mutationEnvelopeCarriesNoCredentials() throws {
        let key = IdempotencyKey(UUID())
        let envelope = MutationEnvelope(
            mutationID: MutationID(key), accountContext: AccountID("acct-1"),
            entityType: .workoutAssignment, entityID: UUID().uuidString, opType: .update,
            payloadSchemaVersion: 1, localTimestamp: t0, expectedServerVersion: nil,
            idempotencyKey: key, correlationID: "corr-1", payload: Data("assignment-snapshot".utf8)
        )
        let json = String(data: try JSONEncoder().encode(envelope), encoding: .utf8)!.lowercased()
        for forbidden in ["token", "bearer", "password", "refresh", "signature=", "secret"] {
            #expect(!json.contains(forbidden), "envelope must not contain \(forbidden)")
        }
    }

    // Typed transport errors expose only a status code, never server internals.
    @Test func transportErrorExposesNoServerInternals() {
        let error = TransportError.serverError(status: 503)
        // Equatable/typed — a status code only; there is no free-form server message field.
        #expect(error == .serverError(status: 503))
    }
}
