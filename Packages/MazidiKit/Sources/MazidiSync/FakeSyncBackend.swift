import Foundation
import MazidiAuth
import MazidiNetworking

// ─────────────────────────────────────────────────────────────────────────────
//  Deterministic in-process backend (ADR-0012 §10). The ONLY implementation of
//  SyncBackendTransport until a real backend exists — it never touches the network and
//  is reproducible run-to-run. Intended for tests and DEBUG development harnesses; a
//  Release build must never select it as a production path (no host is configured, so
//  the real transport is inert and this fake is wired only behind DEBUG/test seams).
// ─────────────────────────────────────────────────────────────────────────────

public actor FakeSyncBackend: SyncBackendTransport {
    private var pushResultsByMutation: [MutationID: MutationResult] = [:]
    private var pushError: TransportError?
    private var pullQueue: [Result<PullChangesResponse, TransportError>] = []
    private var revocation: RevocationCheck = .active
    private var deliveryAck: Result<DeliveryAck, TransportError> = .failure(.unreachable)
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

    // MARK: SyncBackendTransport

    public func push(_ batch: PushMutationBatch, context: AuthenticatedRequestContext) async -> Result<PushAck, TransportError> {
        if Task.isCancelled { return .failure(.cancelled) }
        pushCallCount += 1
        pushedMutationIDs.append(contentsOf: batch.mutations.map(\.mutationID))
        if let pushError { return .failure(pushError) }
        // Only echo results for mutations actually in the batch AND configured; an
        // unconfigured mutation gets no ack entry (the engine keeps it queued).
        var results: [MutationID: MutationResult] = [:]
        for mutation in batch.mutations {
            if let configured = pushResultsByMutation[mutation.mutationID] {
                results[mutation.mutationID] = configured
            }
        }
        return .success(PushAck(results: results))
    }

    public func pull(_ request: PullChangesRequest, context: AuthenticatedRequestContext) async -> Result<PullChangesResponse, TransportError> {
        if Task.isCancelled { return .failure(.cancelled) }
        guard !pullQueue.isEmpty else { return .failure(.unreachable) }
        return pullQueue.removeFirst()
    }

    public func acknowledgeDelivery(remoteID: RemoteRecordID, context: AuthenticatedRequestContext) async -> Result<DeliveryAck, TransportError> {
        if Task.isCancelled { return .failure(.cancelled) }
        return deliveryAck
    }

    public func checkRevocation(context: AuthenticatedRequestContext) async -> RevocationCheck { revocation }
}
