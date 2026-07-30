import Foundation
import Testing
import MazidiDomain
import MazidiFoundations

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)
private let notice = PrivacyNoticeVersion("v1")
private let notice2 = PrivacyNoticeVersion("v2")

@Suite struct HealthDataConsentTests {
    // MARK: - Grant / withdraw / re-grant transitions

    @Test func grantingRecordsPurposeNoticeVersionAndTimestamp() throws {
        let (ledger, record) = try HealthDataConsentLedger()
            .granting(.performanceRecording, noticeVersion: notice, at: t0)

        #expect(record.purpose == .performanceRecording)
        #expect(record.noticeVersion == notice)
        #expect(record.grantedAt == t0)
        #expect(record.withdrawnAt == nil)
        #expect(record.isInForce)
        #expect(ledger.recordInForce(for: .performanceRecording) == record)
    }

    @Test func grantingAPurposeAlreadyInForceIsRefused() throws {
        let (ledger, _) = try HealthDataConsentLedger()
            .granting(.performanceRecording, noticeVersion: notice, at: t0)

        #expect(throws: HealthDataConsentError.alreadyGranted(.performanceRecording)) {
            _ = try ledger.granting(.performanceRecording, noticeVersion: notice, at: t0.addingTimeInterval(60))
        }
    }

    @Test func withdrawingClosesTheRecordWithoutRewritingItsEvidence() throws {
        let (granted, original) = try HealthDataConsentLedger()
            .granting(.coachSharing, noticeVersion: notice, at: t0)
        let withdrawnAt = t0.addingTimeInterval(3600)
        let (ledger, closed) = try granted.withdrawing(.coachSharing, at: withdrawnAt)

        #expect(closed.id == original.id)                    // same record, not a replacement
        #expect(closed.grantedAt == original.grantedAt)       // evidence intact
        #expect(closed.noticeVersion == original.noticeVersion)
        #expect(closed.purpose == original.purpose)
        #expect(closed.withdrawnAt == withdrawnAt)
        #expect(!closed.isInForce)
        #expect(ledger.recordInForce(for: .coachSharing) == nil)
    }

    @Test func withdrawingWithNothingInForceIsRefused() throws {
        #expect(throws: HealthDataConsentError.noConsentInForce(.coachSharing)) {
            _ = try HealthDataConsentLedger().withdrawing(.coachSharing, at: t0)
        }
    }

    @Test func doubleWithdrawalIsRefusedAndCannotMoveTheTimestamp() throws {
        let (granted, _) = try HealthDataConsentLedger()
            .granting(.coachSharing, noticeVersion: notice, at: t0)
        let (once, closed) = try granted.withdrawing(.coachSharing, at: t0.addingTimeInterval(10))

        #expect(throws: HealthDataConsentError.noConsentInForce(.coachSharing)) {
            _ = try once.withdrawing(.coachSharing, at: t0.addingTimeInterval(999))
        }
        var record = closed
        #expect(throws: HealthDataConsentError.alreadyWithdrawn(at: t0.addingTimeInterval(10))) {
            try record.withdraw(at: t0.addingTimeInterval(999))
        }
        #expect(record.withdrawnAt == t0.addingTimeInterval(10))
    }

    @Test func withdrawalCannotPredateItsGrant() throws {
        var record = HealthDataConsent(purpose: .performanceRecording, noticeVersion: notice, grantedAt: t0)
        #expect(throws: HealthDataConsentError.withdrawalPrecedesGrant) {
            try record.withdraw(at: t0.addingTimeInterval(-1))
        }
        #expect(record.isInForce)
    }

    @Test func reGrantingCreatesANewRecordAndLeavesTheWithdrawnOneIntact() throws {
        let (granted, first) = try HealthDataConsentLedger()
            .granting(.performanceRecording, noticeVersion: notice, at: t0)
        let (withdrawn, _) = try granted.withdrawing(.performanceRecording, at: t0.addingTimeInterval(60))
        let (reGranted, second) = try withdrawn
            .granting(.performanceRecording, noticeVersion: notice2, at: t0.addingTimeInterval(120))

        #expect(second.id != first.id)                       // new decision, not a revival
        #expect(second.noticeVersion == notice2)             // consent is to the CURRENT wording
        #expect(reGranted.history(for: .performanceRecording).count == 2)
        let preserved = try #require(reGranted.history(for: .performanceRecording).first)
        #expect(preserved.id == first.id)
        #expect(preserved.withdrawnAt == t0.addingTimeInterval(60))
        #expect(preserved.noticeVersion == notice)           // the old record still names the old wording
        #expect(HealthDataConsentPolicy.mayCollect(.performanceRecording, given: reGranted))
    }

    // MARK: - Withdrawal never deletes history

    @Test func withdrawalNeverShortensTheLedgerOrDropsAnID() throws {
        var ledger = HealthDataConsentLedger()
        for purpose in HealthDataConsent.Purpose.allCases {
            ledger = try ledger.granting(purpose, noticeVersion: notice, at: t0).ledger
        }
        let idsBefore = Set(ledger.records.map(\.id))
        let countBefore = ledger.records.count

        for purpose in HealthDataConsent.Purpose.allCases {
            ledger = try ledger.withdrawing(purpose, at: t0.addingTimeInterval(60)).ledger
        }

        #expect(ledger.records.count == countBefore)          // nothing removed
        #expect(Set(ledger.records.map(\.id)) == idsBefore)   // the same records, closed
        #expect(ledger.records.allSatisfy { $0.grantedAt == t0 })
        #expect(ledger.records.allSatisfy { !$0.isInForce })
    }

    @Test func withdrawalPreservesEveryEarlierRecordAcrossGrantWithdrawCycles() throws {
        var ledger = HealthDataConsentLedger()
        var at = t0
        for _ in 0..<3 {
            ledger = try ledger.granting(.coachSharing, noticeVersion: notice, at: at).ledger
            at = at.addingTimeInterval(60)
            ledger = try ledger.withdrawing(.coachSharing, at: at).ledger
            at = at.addingTimeInterval(60)
        }
        // Three complete grant→withdraw periods, all still on record.
        #expect(ledger.history(for: .coachSharing).count == 3)
        #expect(ledger.history(for: .coachSharing).allSatisfy { $0.withdrawnAt != nil })
    }

    // MARK: - Purposes are independent (unbundled)

    @Test func grantingOnePurposeDoesNotPermitAnother() throws {
        let (ledger, _) = try HealthDataConsentLedger()
            .granting(.performanceRecording, noticeVersion: notice, at: t0)

        #expect(HealthDataConsentPolicy.mayCollect(.performanceRecording, given: ledger))
        #expect(!HealthDataConsentPolicy.mayCollect(.perceivedExertionRecording, given: ledger))
        #expect(!HealthDataConsentPolicy.mayCollect(.coachSharing, given: ledger))
    }

    @Test func withdrawingOnePurposeLeavesTheOthersUntouched() throws {
        var ledger = HealthDataConsentLedger()
        for purpose in HealthDataConsent.Purpose.allCases {
            ledger = try ledger.granting(purpose, noticeVersion: notice, at: t0).ledger
        }
        ledger = try ledger.withdrawing(.perceivedExertionRecording, at: t0.addingTimeInterval(60)).ledger

        #expect(HealthDataConsentPolicy.mayCollect(.performanceRecording, given: ledger))
        #expect(!HealthDataConsentPolicy.mayCollect(.perceivedExertionRecording, given: ledger))
        #expect(HealthDataConsentPolicy.mayCollect(.coachSharing, given: ledger))
    }

    @Test func everyPurposeIsIndependentlyRepresentable() throws {
        // Each purpose is its own record, so any subset is expressible — there is no
        // combination that forces two purposes to move together.
        for purpose in HealthDataConsent.Purpose.allCases {
            let (ledger, _) = try HealthDataConsentLedger().granting(purpose, noticeVersion: notice, at: t0)
            let permitted = HealthDataConsent.Purpose.allCases.filter {
                HealthDataConsentPolicy.mayCollect($0, given: ledger)
            }
            #expect(permitted == [purpose])
        }
    }

    // MARK: - Policy gate

    @Test func policyReportsNeverGrantedBeforeAnyDecision() {
        let decision = HealthDataConsentPolicy.decision(for: .performanceRecording, in: HealthDataConsentLedger())
        #expect(decision == .neverGranted)
        #expect(!decision.isPermitted)
    }

    @Test func policyReportsTheEvidenceBehindAPermission() throws {
        let (ledger, _) = try HealthDataConsentLedger()
            .granting(.coachSharing, noticeVersion: notice, at: t0)
        #expect(HealthDataConsentPolicy.decision(for: .coachSharing, in: ledger)
                == .permitted(noticeVersion: notice, grantedAt: t0))
    }

    @Test func policyReportsWithdrawalWithItsTimestamp() throws {
        let (granted, _) = try HealthDataConsentLedger()
            .granting(.coachSharing, noticeVersion: notice, at: t0)
        let at = t0.addingTimeInterval(42)
        let (ledger, _) = try granted.withdrawing(.coachSharing, at: at)

        #expect(HealthDataConsentPolicy.decision(for: .coachSharing, in: ledger) == .withdrawn(at: at))
        #expect(!HealthDataConsentPolicy.mayCollect(.coachSharing, given: ledger))
    }

    @Test func policyPrefersTheLiveRecordOverAnOlderWithdrawnOne() throws {
        let (granted, _) = try HealthDataConsentLedger()
            .granting(.performanceRecording, noticeVersion: notice, at: t0)
        let (withdrawn, _) = try granted.withdrawing(.performanceRecording, at: t0.addingTimeInterval(60))
        let (reGranted, _) = try withdrawn
            .granting(.performanceRecording, noticeVersion: notice2, at: t0.addingTimeInterval(120))

        #expect(HealthDataConsentPolicy.decision(for: .performanceRecording, in: reGranted)
                == .permitted(noticeVersion: notice2, grantedAt: t0.addingTimeInterval(120)))
    }

    @Test func decisionsByPurposeCoversEveryPurpose() throws {
        let (ledger, _) = try HealthDataConsentLedger()
            .granting(.performanceRecording, noticeVersion: notice, at: t0)
        let all = ledger.decisionsByPurpose
        #expect(all.count == HealthDataConsent.Purpose.allCases.count)
        #expect(all[.performanceRecording]?.isPermitted == true)
        #expect(all[.coachSharing] == .neverGranted)
    }

    // MARK: - Round-trip

    @Test func recordsRoundTripThroughCodableUnchanged() throws {
        let (granted, _) = try HealthDataConsentLedger()
            .granting(.coachSharing, noticeVersion: notice, at: t0)
        let (_, closed) = try granted.withdrawing(.coachSharing, at: t0.addingTimeInterval(5))

        let data = try JSONEncoder().encode(closed)
        let decoded = try JSONDecoder().decode(HealthDataConsent.self, from: data)
        #expect(decoded == closed)
    }
}
