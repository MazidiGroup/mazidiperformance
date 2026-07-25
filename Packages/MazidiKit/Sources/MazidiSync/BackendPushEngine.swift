import Foundation
import MazidiDomain
import MazidiFoundations
import MazidiNetworking
import MazidiPersistence

// ─────────────────────────────────────────────────────────────────────────────
//  Backend push engine (ADR-0012 §3/§9). Builds provider-neutral mutation envelopes
//  from the durable outbox, uploads a bounded batch, and applies the typed results:
//  acknowledged → removed + server version recorded (one transaction); permanent →
//  dead-lettered (never dropped); transient → re-queued with exponential backoff
//  (injected clock + injected randomness, never a sleep). Per-aggregate ordering is
//  preserved by sending at most the earliest due operation per aggregate each drain.
// ─────────────────────────────────────────────────────────────────────────────

public struct BackendPushConfig: Sendable {
    /// Maximum aggregates (⇒ mutations) uploaded per drain — bounded work.
    public var maxBatchSize: Int
    public var baseBackoff: TimeInterval
    public var maxBackoff: TimeInterval
    /// Fraction of the exponential delay added as jitter (× injected random ∈ [0,1)).
    public var jitterFraction: Double
    public var payloadSchemaVersion: Int

    public init(maxBatchSize: Int = 50, baseBackoff: TimeInterval = 2, maxBackoff: TimeInterval = 300, jitterFraction: Double = 0.5, payloadSchemaVersion: Int = 1) {
        self.maxBatchSize = maxBatchSize
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
        self.jitterFraction = jitterFraction
        self.payloadSchemaVersion = payloadSchemaVersion
    }
}

public struct BackendPushSummary: Sendable, Equatable {
    public var attempted = 0
    public var acknowledged = 0
    public var deadLettered = 0
    public var retried = 0
    /// True when the whole batch failed at the transport (not per-mutation).
    public var transportFailed = false
    /// True when the transport reported this session revoked — the caller must route this to
    /// `SessionCoordinator.revocationReported(...)` (ADR-0012 §8). No further work uploads.
    public var revoked = false
    /// True when the drain was skipped because the session was inactive (signed out /
    /// switched / revoked) — proves no pending work uploads after revocation.
    public var skippedInactive = false

    public init() {}
}

public actor BackendPushEngine {
    private let outbox: SyncOutboxStore
    private let syncStore: any BackendSyncStore
    private let transport: any SyncBackendTransport
    private let clock: any AppClock
    private let random: @Sendable () -> Double
    private let config: BackendPushConfig
    /// Session-generation guard: false once the session signed out / switched / was revoked.
    /// Checked BEFORE every send so no pending work uploads after revocation (ADR-0012 §8).
    private let isActive: @Sendable () -> Bool
    private let audit: (any AuditEventStore)?
    private let actorID: UUID

    public init(
        outbox: SyncOutboxStore,
        syncStore: any BackendSyncStore,
        transport: any SyncBackendTransport,
        clock: any AppClock,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        config: BackendPushConfig = BackendPushConfig(),
        isActive: @escaping @Sendable () -> Bool = { true },
        audit: (any AuditEventStore)? = nil,
        actorID: UUID = UUID()
    ) {
        self.outbox = outbox
        self.syncStore = syncStore
        self.transport = transport
        self.clock = clock
        self.random = random
        self.config = config
        self.isActive = isActive
        self.audit = audit
        self.actorID = actorID
    }

    /// Append a sync audit event (ADR-0006 privacy: ids/counts only — never tokens, bodies,
    /// notes, credentials, or signed URLs).
    private func emit(_ kind: AuditEvent.Kind, subject: String, payload: [String: String] = [:]) async {
        guard let audit else { return }
        guard let previous = try? await audit.latestHash() else { return }
        try? await audit.append(AuditEvent(
            kind: kind, actorID: actorID, subjectDescription: subject,
            occurredAt: clock.now(), previousHash: previous, payload: payload
        ))
    }

    /// Deterministic backoff delay for the next attempt (exponential + injected jitter),
    /// or the server's `retry-after` when provided. Never sleeps — returns a due time.
    func backoffDelay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return retryAfter }
        let exponential = min(config.maxBackoff, config.baseBackoff * pow(2, Double(max(0, attempt - 1))))
        return exponential + exponential * config.jitterFraction * random()
    }

    /// Drain one bounded batch of due operations. Returns a summary for the caller/status.
    @discardableResult
    public func pushOnce(context: AuthenticatedRequestContext) async throws -> BackendPushSummary {
        // No pending work uploads after sign-out / switch / revocation.
        guard isActive() else {
            var summary = BackendPushSummary(); summary.skippedInactive = true; return summary
        }
        let now = clock.now()
        let pending = try await outbox.pendingOperations()

        // Earliest due operation per aggregate (preserves per-aggregate ordering across
        // drains), deterministically ordered, bounded.
        var earliestByAggregate: [UUID: SyncOperation] = [:]
        for op in pending where op.isDue(at: now) {
            if let existing = earliestByAggregate[op.aggregateID], existing.sequence <= op.sequence { continue }
            earliestByAggregate[op.aggregateID] = op
        }
        let due = earliestByAggregate.values
            .sorted { ($0.enqueuedAt, $0.sequence) < ($1.enqueuedAt, $1.sequence) }
            .prefix(config.maxBatchSize)

        var summary = BackendPushSummary()
        guard !due.isEmpty else { return summary }
        summary.attempted = due.count

        // Mark in-flight (attempt bump) and build envelopes.
        var envelopes: [MutationEnvelope] = []
        for op in due {
            var marked = op
            marked.markInFlight()
            try await outbox.update(marked)
            envelopes.append(envelope(for: marked, context: context))
        }
        let batch = PushMutationBatch(accountContext: context.accountID, deviceInstallationID: context.deviceInstallationID, mutations: envelopes)
        await emit(.syncBatchAttempted, subject: "batch:\(batch.batchID.uuidString)", payload: ["mutations": "\(envelopes.count)"])

        switch await transport.push(batch, context: context) {
        case let .success(ack):
            var applications: [PushOutcomeApplication] = []
            for op in due {
                // attemptCount after the in-flight bump (used for exponential backoff).
                let attempt = op.attemptCount + 1
                let mutationID = MutationID(IdempotencyKey(op.idempotencyKey))
                let outcome: PushOutcomeApplication.Outcome
                switch ack.results[mutationID] {
                case let .applied(version), let .duplicateApplied(version):
                    outcome = .acknowledged(remoteID: nil, serverVersion: version.rawValue)
                    summary.acknowledged += 1
                case let .rejected(reason):
                    outcome = .deadLettered(reason: Self.describe(reason))
                    summary.deadLettered += 1
                    await emit(.mutationPermanentlyRejected, subject: "\(op.entityType.rawValue):\(op.aggregateID.uuidString)")
                case let .needsRetry(retry):
                    let due = now.addingTimeInterval(backoffDelay(attempt: attempt, retryAfter: retry.retryAfter))
                    outcome = .retry(nextAttemptAt: due, reason: "server requested retry")
                    summary.retried += 1
                case nil:
                    // Stale/unknown/missing ack for a mutation we sent → keep it queued
                    // safely (never drop, never assume applied).
                    let due = now.addingTimeInterval(backoffDelay(attempt: attempt, retryAfter: nil))
                    outcome = .retry(nextAttemptAt: due, reason: "no acknowledgement")
                    summary.retried += 1
                }
                applications.append(PushOutcomeApplication(
                    operationID: op.id.rawValue,
                    entityType: op.entityType.rawValue,
                    localEntityID: op.aggregateID.uuidString,
                    outcome: outcome
                ))
            }
            try await syncStore.applyPushResults(applications, at: now)
            await emit(.syncBatchAcknowledged, subject: "batch:\(batch.batchID.uuidString)",
                       payload: ["acknowledged": "\(summary.acknowledged)", "rejected": "\(summary.deadLettered)", "retried": "\(summary.retried)"])

        case let .failure(error):
            // Whole-batch transport failure: re-queue every attempted op with backoff,
            // honouring a rate-limit's retry-after. Nothing is dropped.
            summary.transportFailed = true
            // A revoked transport signal is surfaced so the caller routes it to the
            // SessionCoordinator; the ops stay queued (never dead-lettered) and the next
            // drain is blocked by the isActive guard once the session is revoked.
            if case .revoked = error { summary.revoked = true; await emit(.revocationDiscovered, subject: "account:\(context.accountID)") }
            let retryAfter: TimeInterval? = { if case let .rateLimited(limit) = error { return limit.retryAfter }; return nil }()
            var applications: [PushOutcomeApplication] = []
            for op in due {
                let attempt = op.attemptCount + 1
                let dueAt = now.addingTimeInterval(backoffDelay(attempt: attempt, retryAfter: retryAfter))
                applications.append(PushOutcomeApplication(
                    operationID: op.id.rawValue,
                    entityType: op.entityType.rawValue,
                    localEntityID: op.aggregateID.uuidString,
                    outcome: .retry(nextAttemptAt: dueAt, reason: Self.describe(error))
                ))
                summary.retried += 1
            }
            try await syncStore.applyPushResults(applications, at: now)
        }
        return summary
    }

    private func envelope(for op: SyncOperation, context: AuthenticatedRequestContext) -> MutationEnvelope {
        let key = IdempotencyKey(op.idempotencyKey)
        return MutationEnvelope(
            mutationID: MutationID(key),
            accountContext: context.accountID,
            entityType: op.entityType,
            entityID: op.aggregateID.uuidString,
            opType: .update,
            payloadSchemaVersion: config.payloadSchemaVersion,
            localTimestamp: op.enqueuedAt,
            expectedServerVersion: nil,
            idempotencyKey: key,
            correlationID: nil,
            payload: op.payload
        )
    }

    private static func describe(_ reason: PermanentRejection) -> String {
        switch reason {
        case let .validationFailed(message): "validation failed: \(message)"
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case let .conflict(version): "conflict at server version \(version.rawValue)"
        case .relationshipEnded: "relationship ended"
        case let .unsupported(message): "unsupported: \(message)"
        }
    }

    private static func describe(_ error: TransportError) -> String {
        switch error {
        case .unreachable: "network unreachable"
        case .timeout: "request timed out"
        case .rateLimited: "rate limited"
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case .revoked: "revoked"
        case let .conflict(version): "conflict at server version \(version.rawValue)"
        case let .serverError(status): "server error \(status)"
        case .malformedResponse: "malformed response"
        case .cancelled: "cancelled"
        }
    }
}
