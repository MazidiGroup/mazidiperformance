import Foundation
import MazidiFoundations

/// Typed, append-only audit record (ADR-0006). Written in the same transaction as the
/// action it describes; hash-chained for application-level tamper evidence.
public struct AuditEvent: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        // Slice-1 relevant
        case workoutSessionStarted
        case workoutSessionCompleted
        case workoutSessionSuperseded
        case exerciseSwapped
        // Foundation set for later phases (taxonomy per ADR-0006)
        case permissionChanged
        case assistantAccessChanged
        case paymentRecorded
        case paymentAmended
        case programmePublished
        case programmeSafetyEdit
        case progressionApproved
        case relationshipEnded
        case dataExportRequested
        case accountDeletionRequested
        case remoteSignOut
        /// Local sign-out on this device (ADR-0008 sign-out sequence).
        case signedOut
        case sensitiveRecordAccessed
        case alertAcknowledged
        case alertResolved
    }

    public let id: Identifier<AuditEvent>
    public let kind: Kind
    public let actorID: UUID
    public let subjectDescription: String
    public let occurredAt: Date
    /// Hex SHA-256-style chain hash of the previous event; genesis events use "0".
    public let previousHash: String
    public let payload: [String: String]

    public init(
        id: Identifier<AuditEvent> = .init(),
        kind: Kind,
        actorID: UUID,
        subjectDescription: String,
        occurredAt: Date,
        previousHash: String,
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.actorID = actorID
        self.subjectDescription = subjectDescription
        self.occurredAt = occurredAt
        self.previousHash = previousHash
        self.payload = payload
    }
}
