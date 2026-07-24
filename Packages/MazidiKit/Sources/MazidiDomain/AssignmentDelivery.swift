import Foundation

/// Delivery/receipt lifecycle of an assignment (ADR-0012 §7), **orthogonal** to its
/// execution `WorkoutAssignment.Status` (queued/started/completed/cancelled). "Queued" is
/// not "Delivered"; server acceptance is not "opened by the client". Advanced only by the
/// real transport — never by the DEBUG relay, and never at `queuedForUpload`.
public enum AssignmentDeliveryState: String, Sendable, Codable, Equatable, CaseIterable {
    /// Written locally; not yet queued for upload.
    case createdLocally
    /// Enqueued for upload to the backend (still only local intent — not delivered).
    case queuedForUpload
    /// The server accepted the assignment record (genuine delivery — audit fires here).
    case acceptedByServer
    /// The server has made it available to the client account.
    case availableToClient
    /// The client opened it (a distinct receipt event from delivery).
    case openedByClient
    /// The server permanently rejected delivery (e.g. relationship ended); user-visible.
    case permanentlyRejected

    /// True only for the state that represents genuine server acceptance — the single
    /// point at which an `assignmentDelivered` audit event may fire (ADR-0012 §10).
    public var isServerAccepted: Bool { self == .acceptedByServer }
}
