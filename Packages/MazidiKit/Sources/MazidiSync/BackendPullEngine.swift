import Foundation
import MazidiFoundations
import MazidiNetworking
import MazidiPersistence

// ─────────────────────────────────────────────────────────────────────────────
//  Backend pull engine (ADR-0012 §4). Client-initiated (no socket). Applies remote
//  changes and advances the account-scoped cursor in ONE transaction; the cursor is
//  monotonic and never regresses; duplicate/out-of-order changes (serverVersion ≤ the
//  cursor) are harmless; tombstones are explicit; an unknown future schema is quarantined
//  honestly (not applied); a pull failure preserves the prior cursor; sign-out / account
//  switch prevents any further application (session-generation guard).
// ─────────────────────────────────────────────────────────────────────────────

public enum BackendPullOutcome: Sendable, Equatable {
    /// Applied `applied` changes (ignored `ignored` duplicates); `hasMore` if paginated.
    case applied(applied: Int, ignored: Int, hasMore: Bool)
    /// The response was for a different account, or the session changed mid-flight — ignored.
    case ignoredStale
    /// A future schema was encountered; nothing applied, cursor preserved, surfaced honestly.
    case quarantinedUnsupportedSchema(serverSchemaVersion: Int)
    /// The transport failed; the prior cursor is preserved.
    case transportFailed(TransportError)
}

public actor BackendPullEngine {
    /// The pull/response + payload schema version this build understands.
    public static let supportedSchemaVersion = 1

    private let syncStore: any BackendSyncStore
    private let transport: any SyncBackendTransport
    private let clock: any AppClock
    private let stream: String
    private let maxChanges: Int
    /// Session-generation guard: false once the session signed out / switched. Checked
    /// AFTER the network await so a delayed prior-session response is never applied.
    private let isActive: @Sendable () -> Bool

    public init(
        syncStore: any BackendSyncStore,
        transport: any SyncBackendTransport,
        clock: any AppClock,
        stream: String = "default",
        maxChanges: Int = 200,
        isActive: @escaping @Sendable () -> Bool = { true }
    ) {
        self.syncStore = syncStore
        self.transport = transport
        self.clock = clock
        self.stream = stream
        self.maxChanges = maxChanges
        self.isActive = isActive
    }

    @discardableResult
    public func pullOnce(context: AuthenticatedRequestContext) async throws -> BackendPullOutcome {
        let existing = try await syncStore.loadSyncCursor(stream: stream) ?? .initial
        let request = PullChangesRequest(
            accountContext: context.accountID, stream: SyncStream(stream),
            cursorToken: existing.token.map(SyncCursorToken.init), maxChanges: maxChanges
        )

        let response: PullChangesResponse
        switch await transport.pull(request, context: context) {
        case let .success(value): response = value
        case let .failure(error): return .transportFailed(error)   // cursor preserved
        }

        // Bind the response to the active account + session; a delayed prior-account or
        // prior-session response is ignored and never applied (isolation, ADR-0012 §2/§4).
        guard isActive(), response.accountContext == context.accountID else { return .ignoredStale }

        // Unknown future schema anywhere → quarantine; apply nothing, cursor preserved.
        guard response.serverSchemaVersion <= Self.supportedSchemaVersion,
              response.changes.allSatisfy({ $0.payloadSchemaVersion <= Self.supportedSchemaVersion })
        else { return .quarantinedUnsupportedSchema(serverSchemaVersion: response.serverSchemaVersion) }

        // Monotonic: accept only changes strictly beyond the cursor; ignore duplicates/
        // out-of-order. The cursor never regresses.
        var applications: [PulledChangeApplication] = []
        var ignored = 0
        var maxSeen = existing.lastServerVersion
        for change in response.changes {
            maxSeen = max(maxSeen, change.serverVersion.rawValue)
            if change.serverVersion.rawValue > existing.lastServerVersion {
                applications.append(PulledChangeApplication(
                    entityType: change.entityType.rawValue,
                    remoteID: change.remoteID.rawValue,
                    serverVersion: change.serverVersion.rawValue,
                    tombstoned: change.op == .tombstone
                ))
            } else {
                ignored += 1
            }
        }

        let advanced = SyncCursorState(
            token: response.nextCursorToken?.rawValue ?? existing.token,
            lastServerVersion: maxSeen,                       // max ⇒ never regresses
            schemaVersion: existing.schemaVersion
        )
        try await syncStore.applyPullChanges(applications, advancingCursorTo: advanced, stream: stream, at: clock.now())
        return .applied(applied: applications.count, ignored: ignored, hasMore: response.hasMore)
    }
}
