#if DEBUG
import Foundation
import MazidiAuth
import MazidiNetworking

// ─────────────────────────────────────────────────────────────────────────────
//  Deterministic in-process backend (ADR-0012 §10). The ONLY implementation of
//  SyncBackendTransport. Compiled out of Release entirely (`#if DEBUG`) so it can never
//  be selected as a production path and never appears in the shipping binary — the
//  Release provider slot stays failing/honest until a real backend exists. Never touches
//  the network; reproducible run-to-run. For tests and DEBUG development harnesses only.
// ─────────────────────────────────────────────────────────────────────────────

public actor FakeSyncBackend: SyncBackendTransport {
    private var pushResultsByMutation: [MutationID: MutationResult] = [:]
    private var pushError: TransportError?
    private var pullQueue: [Result<PullChangesResponse, TransportError>] = []
    private var revocation: RevocationCheck = .active
    private var deliveryAck: Result<DeliveryAck, TransportError> = .failure(.unreachable)
    /// Dev connectivity toggle: when offline the transport is unreachable (ops stay queued).
    private var online = true
    /// When true, a mutation with no explicit configured result is auto-acknowledged
    /// (applied) with a monotonic server version — used by the in-app dev drain so the
    /// honest offline → syncing → up-to-date flow works without pre-configuring each op.
    private var autoAck = false
    private var nextVersion = 1
    /// Every mutation id ever uploaded, in order — lets tests assert that a retry reuses
    /// the same deterministic id (no duplicate mutation).
    public private(set) var pushedMutationIDs: [MutationID] = []
    public private(set) var pushCallCount = 0

    public init() {}

    // MARK: Configuration (deterministic)

    public func setPushResult(_ result: MutationResult, for mutation: MutationID) { pushResultsByMutation[mutation] = result }
    public func setPushError(_ error: TransportError?) { pushError = error }
    public func enqueuePull(_ response: Result<PullChangesResponse, TransportError>) { pullQueue.append(response) }
    public func setRevocation(_ check: RevocationCheck) { revocation = check }
    public func setDeliveryAck(_ ack: Result<DeliveryAck, TransportError>) { deliveryAck = ack }
    public func setOnline(_ value: Bool) { online = value }
    public func setAutoAck(_ value: Bool) { autoAck = value }
    public var isOnline: Bool { online }

    // MARK: SyncBackendTransport

    public func push(_ batch: PushMutationBatch, context: AuthenticatedRequestContext) async -> Result<PushAck, TransportError> {
        if Task.isCancelled { return .failure(.cancelled) }
        pushCallCount += 1
        pushedMutationIDs.append(contentsOf: batch.mutations.map(\.mutationID))
        guard online else { return .failure(.unreachable) }
        if let pushError { return .failure(pushError) }
        var results: [MutationID: MutationResult] = [:]
        for mutation in batch.mutations {
            if let configured = pushResultsByMutation[mutation.mutationID] {
                results[mutation.mutationID] = configured
            } else if autoAck {
                results[mutation.mutationID] = .applied(ServerRecordVersion(nextVersion))
                nextVersion += 1
            }
            // Otherwise no ack entry → the engine keeps it queued.
        }
        return .success(PushAck(results: results))
    }

    public func pull(_ request: PullChangesRequest, context: AuthenticatedRequestContext) async -> Result<PullChangesResponse, TransportError> {
        if Task.isCancelled { return .failure(.cancelled) }
        guard online else { return .failure(.unreachable) }
        guard !pullQueue.isEmpty else {
            // Nothing queued: an empty, up-to-date response (idempotent).
            return .success(PullChangesResponse(changes: [], nextCursorToken: request.cursorToken, hasMore: false, serverSchemaVersion: 1, accountContext: request.accountContext))
        }
        return pullQueue.removeFirst()
    }

    public func acknowledgeDelivery(remoteID: RemoteRecordID, context: AuthenticatedRequestContext) async -> Result<DeliveryAck, TransportError> {
        if Task.isCancelled { return .failure(.cancelled) }
        return deliveryAck
    }

    public func checkRevocation(context: AuthenticatedRequestContext) async -> RevocationCheck { revocation }
}
#endif
