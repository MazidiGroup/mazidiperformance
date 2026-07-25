import Foundation

// ─────────────────────────────────────────────────────────────────────────────
//  Typed sync-conflict model (ADR-0012 §5, ARCHITECTURE §5). Every conflict class has a
//  deterministic, per-entity resolution. There is NO generic last-write-wins: version
//  conflicts are resolved by comparing server VERSIONS (a monotonic version vector), never
//  wall-clock timestamps. The immutability / completed-history / relationship safety rules
//  are encoded here so no call site can weaken them.
// ─────────────────────────────────────────────────────────────────────────────

/// The ten conflict classes. Each carries just enough context to resolve deterministically.
public enum SyncConflict: Sendable, Equatable {
    /// The server record moved to a newer version than the local copy.
    case remoteVersionAdvanced(localVersion: Int, remoteVersion: Int)
    /// The record was deleted remotely. `localIsHistoricalTruth` marks completed/immutable
    /// records that must never be erased.
    case localRecordDeletedRemotely(localIsHistoricalTruth: Bool)
    /// An assignment was cancelled on the server. `localCompleted` marks a client session
    /// that already completed (its history must survive).
    case assignmentCancelledRemotely(localCompleted: Bool)
    /// A published version's frozen content differs from the server's — must never rewrite.
    case immutableVersionMismatch
    /// The Coach–Client relationship ended.
    case relationshipEnded
    /// The actor's permission for this record was revoked.
    case permissionRevoked
    /// The change uses a schema this build does not understand.
    case unsupportedSchema(Int)
    /// The server reported a state the client cannot make sense of.
    case invalidServerState(String)
    /// A completion the server has already recorded (the client tried again).
    case duplicateCompletion
    /// A local mutation the server permanently rejected (validation/authorization).
    case localMutationPermanentlyRejected(String)
}

/// The deterministic outcome. Nothing here silently overwrites data.
public enum ConflictResolution: Sendable, Equatable {
    /// Accept the remote change (a strictly newer server version — version-based, not LWW).
    case applyRemote
    /// Keep the local record because it is historical truth (completed history / published
    /// immutable version); the remote change never rewrites it.
    case keepLocalHistoricalTruth(reason: String)
    /// Coach-authored drafts: concurrent edits require an explicit merge; nothing is
    /// overwritten silently.
    case requiresManualMerge(reason: String)
    /// Block new access but retain existing history (relationship ended / permission revoked).
    case blockNewAccessRetainHistory(reason: String)
    /// A no-op: the change was already applied (duplicate by key / duplicate completion).
    case idempotentNoOp
    /// Surface honestly and apply nothing (unsupported schema / invalid server state).
    case surfaceUnsupported(reason: String)
    /// Park the local mutation as permanently rejected (user-visible, never dropped).
    case parkRejected(reason: String)
}

public enum ConflictResolver {
    /// Pure, deterministic resolution. Same conflict → same resolution, always.
    public static func resolve(_ conflict: SyncConflict) -> ConflictResolution {
        switch conflict {
        case let .remoteVersionAdvanced(localVersion, remoteVersion):
            // Version vector, NOT timestamps: accept only a strictly newer server version;
            // an equal or older version is already-applied (no-op), never overwritten.
            return remoteVersion > localVersion ? .applyRemote : .idempotentNoOp

        case let .localRecordDeletedRemotely(localIsHistoricalTruth):
            return localIsHistoricalTruth
                ? .keepLocalHistoricalTruth(reason: "completed/immutable history is never erased by a remote deletion")
                : .applyRemote

        case let .assignmentCancelledRemotely(localCompleted):
            // A remote cancellation can never erase a completed session's history.
            return localCompleted
                ? .keepLocalHistoricalTruth(reason: "a completed session is never erased by a remote cancellation")
                : .applyRemote

        case .immutableVersionMismatch:
            return .keepLocalHistoricalTruth(reason: "published versions are immutable and completed history is never rewritten")

        case .relationshipEnded:
            return .blockNewAccessRetainHistory(reason: "relationship ended: block new access, retain existing history")

        case .permissionRevoked:
            return .blockNewAccessRetainHistory(reason: "permission revoked: block new access, retain existing history")

        case let .unsupportedSchema(version):
            return .surfaceUnsupported(reason: "unsupported schema version \(version)")

        case let .invalidServerState(message):
            return .surfaceUnsupported(reason: "invalid server state: \(message)")

        case .duplicateCompletion:
            return .idempotentNoOp

        case let .localMutationPermanentlyRejected(message):
            return .parkRejected(reason: message)
        }
    }
}
