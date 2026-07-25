import Foundation
import MazidiDomain
import MazidiFoundations
import MazidiNetworking
import MazidiPersistence

// ─────────────────────────────────────────────────────────────────────────────
//  Backend pull engine (ADR-0012 §4). Client-initiated (no socket). Materialises
//  decoded domain rows (assignment/relationship) AND advances the account-scoped cursor
//  in ONE transaction; the cursor is monotonic and never regresses; duplicate/out-of-order
//  changes (serverVersion ≤ the cursor) are harmless; tombstones are explicit; an unknown
//  future schema OR an undecodable materialisable payload is quarantined honestly (nothing
//  applied, cursor preserved); a pull failure preserves the prior cursor; sign-out / account
//  switch prevents any further application (session-generation guard).
// ─────────────────────────────────────────────────────────────────────────────

public enum BackendPullOutcome: Sendable, Equatable {
    /// Applied `applied` changes (ignored `ignored` duplicates); `hasMore` if paginated.
    case applied(applied: Int, ignored: Int, hasMore: Bool)
    /// The response was for a different account, or the session changed mid-flight — ignored.
    case ignoredStale
    /// A future schema was encountered; nothing applied, cursor preserved, surfaced honestly.
    case quarantinedUnsupportedSchema(serverSchemaVersion: Int)
    /// A materialisable payload could not be decoded; nothing applied, cursor preserved.
    case quarantinedUndecodablePayload(entityType: String)
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
    private let isActive: @Sendable () -> Bool
    private let audit: (any AuditEventStore)?
    private let actorID: UUID
    private let decoder = JSONDecoder()

    public init(
        syncStore: any BackendSyncStore,
        transport: any SyncBackendTransport,
        clock: any AppClock,
        stream: String = "default",
        maxChanges: Int = 200,
        isActive: @escaping @Sendable () -> Bool = { true },
        audit: (any AuditEventStore)? = nil,
        actorID: UUID = UUID()
    ) {
        self.syncStore = syncStore
        self.transport = transport
        self.clock = clock
        self.stream = stream
        self.maxChanges = maxChanges
        self.isActive = isActive
        self.audit = audit
        self.actorID = actorID
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
        // out-of-order. Decode materialisable payloads; an undecodable one quarantines the
        // batch (never advance past a change whose domain effect can't be applied).
        var materializations: [PulledMaterialization] = []
        var ignored = 0
        var maxSeen = existing.lastServerVersion
        for change in response.changes {
            maxSeen = max(maxSeen, change.serverVersion.rawValue)
            guard change.serverVersion.rawValue > existing.lastServerVersion else { ignored += 1; continue }

            let entity: PulledMaterialization.Entity
            if change.op == .tombstone {
                entity = .tombstone
            } else {
                switch change.entityType {
                case .workoutAssignment:
                    guard let data = change.payload, let assignment = try? decoder.decode(WorkoutAssignment.self, from: data) else {
                        return .quarantinedUndecodablePayload(entityType: change.entityType.rawValue)
                    }
                    entity = .assignment(assignment)
                case .relationship:
                    guard let data = change.payload, let relationship = try? decoder.decode(Relationship.self, from: data) else {
                        return .quarantinedUndecodablePayload(entityType: change.entityType.rawValue)
                    }
                    entity = .relationship(relationship)
                default:
                    entity = .trackVersionOnly
                }
            }
            materializations.append(PulledMaterialization(
                entityType: change.entityType.rawValue, remoteID: change.remoteID.rawValue,
                serverVersion: change.serverVersion.rawValue, entity: entity
            ))
        }

        let advanced = SyncCursorState(
            token: response.nextCursorToken?.rawValue ?? existing.token,
            lastServerVersion: maxSeen,                       // max ⇒ never regresses
            schemaVersion: existing.schemaVersion
        )
        try await syncStore.applyPullChanges(materializations, advancingCursorTo: advanced, stream: stream, at: clock.now())

        if !materializations.isEmpty { await emitPullApplied(count: materializations.count, version: advanced.lastServerVersion) }
        return .applied(applied: materializations.count, ignored: ignored, hasMore: response.hasMore)
    }

    /// pullChangesApplied audit (ADR-0006 privacy: counts + version only, never content).
    private func emitPullApplied(count: Int, version: Int) async {
        guard let audit else { return }
        guard let previous = try? await audit.latestHash() else { return }
        try? await audit.append(AuditEvent(
            kind: .pullChangesApplied, actorID: actorID,
            subjectDescription: "stream:\(stream)", occurredAt: clock.now(), previousHash: previous,
            payload: ["applied": "\(count)", "version": "\(version)"]
        ))
    }
}
