import Foundation
import MazidiFoundations

/// A Coach–Client relationship (ADR-0012 §6). Domain stays auth-free: coach/client are
/// opaque account reference strings (as `WorkoutAssignment.assigneeAccountRef` is), never
/// emails. Relationship-level authorization is **advisory locally** — real enforcement of
/// "which coach may relate to which client" is a backend responsibility (R-01/R-02); this
/// type models the local lifecycle only.
public struct Relationship: Sendable, Codable, Equatable, Identifiable {
    /// Lifecycle status (ADR-0012 §6). Local transitions are guarded; server confirmation
    /// arrives with the backend (the `pending*` states are honest local-only intents).
    public enum Status: String, Sendable, Codable, CaseIterable {
        case invited
        case active
        case declined
        case ended
        case revoked
        /// Created locally, queued for upload (not yet server-acknowledged).
        case pendingLocalUpload
        /// Uploaded, awaiting server confirmation.
        case pendingRemoteConfirmation
    }

    /// Local sync state, mirroring the assignment pattern.
    public enum LocalSyncState: String, Sendable, Codable {
        case synced
        case pendingUpload
        case pendingConfirmation
    }

    public enum LifecycleError: Error, Equatable, Sendable {
        case illegalTransition(from: Status, to: Status)
    }

    public let id: Identifier<Relationship>
    public let coachAccountRef: String
    public let clientAccountRef: String
    public private(set) var status: Status
    public let createdAt: Date
    public private(set) var acceptedAt: Date?
    public private(set) var endedAt: Date?
    public let serverVersion: Int
    public private(set) var localSyncState: LocalSyncState

    public init(
        id: Identifier<Relationship> = .init(),
        coachAccountRef: String,
        clientAccountRef: String,
        status: Status = .pendingLocalUpload,
        createdAt: Date,
        acceptedAt: Date? = nil,
        endedAt: Date? = nil,
        serverVersion: Int = 0,
        localSyncState: LocalSyncState = .pendingUpload
    ) {
        self.id = id
        self.coachAccountRef = coachAccountRef
        self.clientAccountRef = clientAccountRef
        self.status = status
        self.createdAt = createdAt
        self.acceptedAt = acceptedAt
        self.endedAt = endedAt
        self.serverVersion = serverVersion
        self.localSyncState = localSyncState
    }

    /// Full restoration initializer (persistence).
    public init(
        restoring id: Identifier<Relationship>,
        coachAccountRef: String,
        clientAccountRef: String,
        status: Status,
        createdAt: Date,
        acceptedAt: Date?,
        endedAt: Date?,
        serverVersion: Int,
        localSyncState: LocalSyncState
    ) {
        self.id = id
        self.coachAccountRef = coachAccountRef
        self.clientAccountRef = clientAccountRef
        self.status = status
        self.createdAt = createdAt
        self.acceptedAt = acceptedAt
        self.endedAt = endedAt
        self.serverVersion = serverVersion
        self.localSyncState = localSyncState
    }

    // MARK: - Guarded lifecycle transitions

    /// Move to `active` (invitation accepted / server-confirmed). Legal from invited or
    /// either pending state.
    public mutating func activate(at now: Date) throws {
        guard [.invited, .pendingLocalUpload, .pendingRemoteConfirmation].contains(status) else {
            throw LifecycleError.illegalTransition(from: status, to: .active)
        }
        status = .active
        acceptedAt = now
        localSyncState = .synced
    }

    /// Decline a pending invitation.
    public mutating func decline(at now: Date) throws {
        guard status == .invited else { throw LifecycleError.illegalTransition(from: status, to: .declined) }
        status = .declined
        endedAt = now
    }

    /// End an active relationship (blocks new access; existing history retained — ADR-0012 §5).
    public mutating func end(at now: Date) throws {
        guard status == .active else { throw LifecycleError.illegalTransition(from: status, to: .ended) }
        status = .ended
        endedAt = now
    }

    /// Revoke (e.g. discovered revoked on the server). Legal from any non-terminal state.
    public mutating func revoke(at now: Date) throws {
        guard ![.declined, .ended, .revoked].contains(status) else {
            throw LifecycleError.illegalTransition(from: status, to: .revoked)
        }
        status = .revoked
        endedAt = now
    }

    /// True while the relationship permits new coach→client actions (advisory locally).
    public var permitsNewAccess: Bool { status == .active }
}
