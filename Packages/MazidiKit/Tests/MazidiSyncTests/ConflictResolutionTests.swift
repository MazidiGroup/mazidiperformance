import Foundation
import Testing
@testable import MazidiSync

@Suite struct ConflictResolutionTests {
    // Remote version advanced → accept (version-based, never timestamp last-write-wins).
    @Test func remoteVersionAdvancedAppliesRemote() {
        #expect(ConflictResolver.resolve(.remoteVersionAdvanced(localVersion: 2, remoteVersion: 3)) == .applyRemote)
    }

    // Equal/older server version is already applied — never overwritten (no LWW).
    @Test func equalOrOlderRemoteVersionIsNoOpNotOverwrite() {
        #expect(ConflictResolver.resolve(.remoteVersionAdvanced(localVersion: 3, remoteVersion: 3)) == .idempotentNoOp)
        #expect(ConflictResolver.resolve(.remoteVersionAdvanced(localVersion: 5, remoteVersion: 4)) == .idempotentNoOp)
    }

    // Published version mismatch never rewrites the immutable version / completed history.
    @Test func immutableVersionMismatchKeepsLocal() {
        if case .keepLocalHistoricalTruth = ConflictResolver.resolve(.immutableVersionMismatch) {} else {
            Issue.record("expected keepLocalHistoricalTruth")
        }
    }

    // A remote cancellation must NOT erase a completed session; but may cancel a non-completed one.
    @Test func remoteCancellationCannotEraseACompletedSession() {
        if case .keepLocalHistoricalTruth = ConflictResolver.resolve(.assignmentCancelledRemotely(localCompleted: true)) {} else {
            Issue.record("a completed session must be preserved")
        }
        #expect(ConflictResolver.resolve(.assignmentCancelledRemotely(localCompleted: false)) == .applyRemote)
    }

    // Duplicate completion is idempotent.
    @Test func duplicateCompletionIsIdempotent() {
        #expect(ConflictResolver.resolve(.duplicateCompletion) == .idempotentNoOp)
    }

    // Relationship ended / permission revoked block new access but retain history.
    @Test func relationshipAndPermissionBlockNewAccessButRetainHistory() {
        for conflict in [SyncConflict.relationshipEnded, .permissionRevoked] {
            if case .blockNewAccessRetainHistory = ConflictResolver.resolve(conflict) {} else {
                Issue.record("expected blockNewAccessRetainHistory for \(conflict)")
            }
        }
    }

    // Unsupported / invalid conflicts are surfaced honestly (nothing applied).
    @Test func unsupportedAndInvalidAreSurfacedHonestly() {
        if case .surfaceUnsupported = ConflictResolver.resolve(.unsupportedSchema(9)) {} else {
            Issue.record("expected surfaceUnsupported")
        }
        if case .surfaceUnsupported = ConflictResolver.resolve(.invalidServerState("nonsense")) {} else {
            Issue.record("expected surfaceUnsupported")
        }
    }

    // Completed/immutable history is preserved when the record is deleted remotely.
    @Test func remoteDeletionNeverErasesHistoricalTruth() {
        if case .keepLocalHistoricalTruth = ConflictResolver.resolve(.localRecordDeletedRemotely(localIsHistoricalTruth: true)) {} else {
            Issue.record("historical truth must be preserved")
        }
        #expect(ConflictResolver.resolve(.localRecordDeletedRemotely(localIsHistoricalTruth: false)) == .applyRemote)
    }

    // A permanently-rejected local mutation is parked (never dropped).
    @Test func permanentlyRejectedLocalMutationIsParked() {
        #expect(ConflictResolver.resolve(.localMutationPermanentlyRejected("bad")) == .parkRejected(reason: "bad"))
    }

    // Resolution is deterministic (same input → same output).
    @Test func resolutionIsDeterministic() {
        let conflicts: [SyncConflict] = [
            .remoteVersionAdvanced(localVersion: 1, remoteVersion: 2), .immutableVersionMismatch,
            .assignmentCancelledRemotely(localCompleted: true), .duplicateCompletion,
            .relationshipEnded, .permissionRevoked, .unsupportedSchema(3), .invalidServerState("x"),
            .localRecordDeletedRemotely(localIsHistoricalTruth: true), .localMutationPermanentlyRejected("y"),
        ]
        for conflict in conflicts {
            #expect(ConflictResolver.resolve(conflict) == ConflictResolver.resolve(conflict))
        }
        // No resolution silently overwrites: none maps to a bare "apply remote" for the
        // history-protecting classes.
        #expect(ConflictResolver.resolve(.immutableVersionMismatch) != .applyRemote)
        #expect(ConflictResolver.resolve(.assignmentCancelledRemotely(localCompleted: true)) != .applyRemote)
    }
}
