import Foundation
import MazidiDomain
import MazidiFoundations

/// PROPOSED backend contracts (DL-11). No backend exists yet (R-01) — these protocols are
/// the client's requirement spec. Nothing in the app may assume behaviour beyond them,
/// and no implementation here fabricates a live service.

public protocol AuthenticationEndpoint: Sendable {
    func signIn(email: String, password: String) async throws -> SessionToken
    func refresh(_ token: SessionToken) async throws -> SessionToken
    func signOutEverywhere(_ token: SessionToken) async throws
}

public struct SessionToken: Sendable, Codable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Workout sync contract (slice 1). Server requirements (R-02):
/// - apply each idempotency key at most once; replays return the stored result
/// - maintain the per-client session epoch for the one-device rule (5f)
public protocol WorkoutSyncEndpoint: Sendable {
    /// Claim the active-session epoch for this client+workout; server increments and
    /// returns the new epoch. Other devices' sessions with older epochs are superseded.
    func claimSessionEpoch(workoutID: Identifier<AssignedWorkout>) async throws -> Int

    /// Push one serialized operation. Must be idempotent per key.
    func push(operationPayload: Data, idempotencyKey: UUID) async throws
}

/// Media manifest contract mirroring `asset-cdn-integration.md` / ASSET_PIPELINE.md.
public struct MediaManifestRecord: Sendable, Codable, Equatable {
    public let slug: ExerciseSlug
    public let displayName: String
    public let posterAssetKey: String
    public let videoAssetKey: String
    public let videoVersion: Int
    public let durationMs: Int
    public let width: Int
    public let height: Int
    public let checksum: String
    public let availabilityStatus: String
    public let contentReviewStatus: String
}

public protocol MediaManifestEndpoint: Sendable {
    func currentManifest() async throws -> [MediaManifestRecord]
}
