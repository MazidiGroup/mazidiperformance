import Foundation
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiSync

/// Health-data consent use-cases (ADR-0013 "Consent and data-protection model").
///
/// Responsibilities: hold the account's append-only consent ledger, record grants and
/// withdrawals durably (each with its outbox operation and audit event in one transaction —
/// ADR-0003/0006), and answer the gate question every health-collection call site must ask.
///
/// The gate answer comes from `HealthDataConsentPolicy` — the same pure function the domain
/// tests exercise — so no surface can hand-roll its own version of the rule (the ADR-0004
/// pattern applied to consent).
///
/// No backend behaviour is fabricated: consent is recorded locally and queued in the outbox
/// exactly like every other mutation (R-01/R-02).
public actor HealthDataConsentService {
    /// The store roles a consent write needs. Both handles reference the same underlying
    /// store, so the consent row, its outbox operation and its audit event share one
    /// transaction scope.
    public struct StoreBundle: Sendable {
        public let consent: HealthDataConsentStore
        public let operations: SyncOutboxStore

        public init(consent: HealthDataConsentStore, operations: SyncOutboxStore) {
            self.consent = consent
            self.operations = operations
        }
    }

    private let store: StoreBundle
    private let clock: any AppClock
    private let actorID: UUID
    private let encoder = JSONEncoder()

    /// Cached ledger. Loaded on first use and kept in step with every write this service
    /// performs; `reload()` re-reads from the store.
    private var cachedLedger: HealthDataConsentLedger?

    public init(store: StoreBundle, clock: any AppClock, actorID: UUID) {
        self.store = store
        self.clock = clock
        self.actorID = actorID
    }

    // MARK: - Reading current state

    public func ledger() async throws -> HealthDataConsentLedger {
        if let cachedLedger { return cachedLedger }
        return try await reload()
    }

    @discardableResult
    public func reload() async throws -> HealthDataConsentLedger {
        let loaded = try await store.consent.consentLedger()
        cachedLedger = loaded
        return loaded
    }

    /// The full decision (with the evidence behind a permission) for one purpose.
    public func decision(for purpose: HealthDataConsent.Purpose) async throws -> HealthDataCollectionDecision {
        HealthDataConsentPolicy.decision(for: purpose, in: try await ledger())
    }

    /// **The gate.** May the app collect/record health data for this purpose right now?
    public func mayCollect(_ purpose: HealthDataConsent.Purpose) async throws -> Bool {
        HealthDataConsentPolicy.mayCollect(purpose, given: try await ledger())
    }

    /// Every purpose's decision in one read — what the consent and privacy screens render.
    public func allDecisions() async throws -> [HealthDataConsent.Purpose: HealthDataCollectionDecision] {
        try await ledger().decisionsByPurpose
    }

    // MARK: - Recording decisions

    /// Grant consent for the given purposes against a specific notice version.
    ///
    /// Each purpose is recorded as its **own** record, with its own outbox operation and audit
    /// event, in its own transaction — a grant of three purposes is three independent
    /// decisions, not one bundled agreement, and a purpose the user did not tick is simply
    /// never passed here.
    ///
    /// Purposes already in force are skipped (idempotent re-submission), never duplicated.
    @discardableResult
    public func grant(
        _ purposes: [HealthDataConsent.Purpose],
        noticeVersion: PrivacyNoticeVersion
    ) async throws -> HealthDataConsentLedger {
        var working = try await ledger()
        for purpose in purposes {
            let now = clock.now()
            let outcome: (ledger: HealthDataConsentLedger, record: HealthDataConsent)
            do {
                outcome = try working.granting(purpose, noticeVersion: noticeVersion, at: now)
            } catch HealthDataConsentError.alreadyGranted {
                continue                                   // already in force — nothing to record
            }
            let aggregate = outcome.record.id.rawValue
            let operation = SyncOperation(
                kind: .healthDataConsentGranted,
                aggregateID: aggregate,
                sequence: try await store.operations.nextSequence(forAggregate: aggregate),
                payload: try encoder.encode(outcome.record),
                enqueuedAt: now
            )
            try await store.consent.grantConsentAtomically(
                outcome.record,
                enqueueing: [operation],
                auditing: audit(.healthDataConsentGranted, record: outcome.record, at: now)
            )
            working = outcome.ledger
        }
        cachedLedger = working
        return working
    }

    /// Withdraw consent for one purpose.
    ///
    /// This stops **future** collection for that purpose and does nothing else: it does not
    /// touch sessions, set entries, or any other recorded data, and it cannot — this service
    /// holds no handle that could delete them. The withdrawn record stays in the ledger as
    /// evidence that consent existed for the earlier period.
    @discardableResult
    public func withdraw(_ purpose: HealthDataConsent.Purpose) async throws -> HealthDataConsentLedger {
        let working = try await ledger()
        let now = clock.now()
        let outcome = try working.withdrawing(purpose, at: now)
        let aggregate = outcome.record.id.rawValue
        let operation = SyncOperation(
            kind: .healthDataConsentWithdrawn,
            aggregateID: aggregate,
            sequence: try await store.operations.nextSequence(forAggregate: aggregate),
            payload: try encoder.encode(outcome.record),
            enqueuedAt: now
        )
        try await store.consent.withdrawConsentAtomically(
            recordID: outcome.record.id,
            at: now,
            enqueueing: [operation],
            auditing: audit(.healthDataConsentWithdrawn, record: outcome.record, at: now)
        )
        cachedLedger = outcome.ledger
        return outcome.ledger
    }

    // MARK: - Audit

    /// Subject = the consent record id; payload = purpose identifier + notice version. No
    /// health content, no measurement, no free text ever reaches the audit log (ADR-0006).
    private func audit(
        _ kind: AuditEvent.Kind,
        record: HealthDataConsent,
        at now: Date
    ) -> PendingAuditEvent {
        PendingAuditEvent(
            kind: kind,
            actorID: actorID,
            subjectDescription: "healthDataConsent:\(record.id)",
            occurredAt: now,
            payload: [
                "purpose": record.purpose.auditIdentifier,
                "noticeVersion": record.noticeVersion.rawValue,
            ]
        )
    }
}
