import Foundation
import MazidiFoundations

/// Version identifier of the privacy notice a consent decision was given against.
///
/// Consent is consent *to a specific text*, so the text must be versioned and the version
/// retained with the decision (ADR-0013, "Consent and data-protection model"). This type is
/// deliberately opaque: the domain never holds notice wording, only the identifier of the
/// wording that was shown.
public struct PrivacyNoticeVersion: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// One immutable consent decision, for **exactly one purpose**.
///
/// Shape (ADR-0013): the record is the evidential unit — `grantedAt` records when consent was
/// given, `noticeVersion` records which wording it was given against, `purpose` records what it
/// covers, and `withdrawnAt` records if/when it stopped applying. Every field except
/// `withdrawnAt` is `let`: a withdrawal can only *close* a record, never rewrite the evidence
/// that consent existed, and a re-grant is a **new record**, never a revival of an old one.
///
/// One purpose per record is what makes unbundling structural rather than conventional: there
/// is no representable object that carries several purposes under one grant timestamp and one
/// withdrawal switch, so a single "I agree" covering several purposes cannot be constructed.
public struct HealthDataConsent: Sendable, Codable, Equatable, Identifiable {
    /// The purposes the app can ask for, each grounded in data the app actually stores today
    /// (`GRDBSchema.swift`). Purposes are **not** speculative: a purpose is only offered when
    /// there is a real collection surface behind it.
    public enum Purpose: String, Sendable, Codable, CaseIterable, Equatable {
        /// Recording what you did in a session — reps, load, duration, distance — and the
        /// session record itself. Collection surface: `set_entry.value_json`,
        /// `workout_session`.
        case performanceRecording

        /// Recording how hard a set felt (RPE / rate of perceived exertion) — a subjective
        /// exertion indicator, separable from the objective performance numbers because the
        /// app already records it through a separate, optional control. Collection surface:
        /// `set_entry.rpe`.
        case perceivedExertionRecording

        /// Sharing recorded training information with your coach. Distinct from recording:
        /// a client may record locally without sharing. Collection surface: the outbox push
        /// path (ADR-0003/0012).
        case coachSharing

        /// Stable identifier safe for audit subjects and sync payloads — a purpose name, never
        /// health content.
        public var auditIdentifier: String { rawValue }
    }

    public let id: Identifier<HealthDataConsent>
    public let purpose: Purpose
    /// Which privacy-notice wording this consent was given against.
    public let noticeVersion: PrivacyNoticeVersion
    public let grantedAt: Date
    /// Set once, never cleared. `nil` means the record is still in force.
    public private(set) var withdrawnAt: Date?

    public init(
        id: Identifier<HealthDataConsent> = .init(),
        purpose: Purpose,
        noticeVersion: PrivacyNoticeVersion,
        grantedAt: Date
    ) {
        self.id = id
        self.purpose = purpose
        self.noticeVersion = noticeVersion
        self.grantedAt = grantedAt
        self.withdrawnAt = nil
    }

    /// Persistence-restoration initializer (ADR-0007): reconstructs a record in an arbitrary
    /// durable state. Not for feature code — decisions go through `withdraw(at:)` and the
    /// ledger's guarded transitions.
    public init(
        restoring id: Identifier<HealthDataConsent>,
        purpose: Purpose,
        noticeVersion: PrivacyNoticeVersion,
        grantedAt: Date,
        withdrawnAt: Date?
    ) {
        self.id = id
        self.purpose = purpose
        self.noticeVersion = noticeVersion
        self.grantedAt = grantedAt
        self.withdrawnAt = withdrawnAt
    }

    /// True while this record still permits collection for its purpose.
    public var isInForce: Bool { withdrawnAt == nil }

    /// Close this record. The only mutation the type allows, and it is one-way: `grantedAt`,
    /// `noticeVersion` and `purpose` are immutable, so the evidence that consent once existed
    /// survives the withdrawal intact (Art. 7(1) demonstrability, ADR-0013).
    ///
    /// Withdrawal stops **future** collection for the purpose. It does not, and cannot, delete
    /// anything already recorded — this type has no reference to recorded data and no API that
    /// could remove any (CLAUDE.md: sharing off stops future sharing, never deletes past
    /// content).
    public mutating func withdraw(at now: Date) throws {
        if let withdrawnAt { throw HealthDataConsentError.alreadyWithdrawn(at: withdrawnAt) }
        guard now >= grantedAt else { throw HealthDataConsentError.withdrawalPrecedesGrant }
        withdrawnAt = now
    }
}

public enum HealthDataConsentError: Error, Equatable, Sendable {
    case alreadyWithdrawn(at: Date)
    case withdrawalPrecedesGrant
    /// A purpose already has a record in force; granting again would create a duplicate
    /// in-force record for one purpose.
    case alreadyGranted(HealthDataConsent.Purpose)
    /// Nothing to withdraw — no record is in force for this purpose.
    case noConsentInForce(HealthDataConsent.Purpose)
}

// MARK: - Ledger (append-only history)

/// The append-only history of consent decisions for one account.
///
/// The ledger has **no removal API** — `granting` appends, `withdrawing` closes an existing
/// record in place and returns a ledger of the *same length with the same ids*. There is no
/// call site, in this package or the app, that can shorten the history: deletion is simply not
/// expressible.
public struct HealthDataConsentLedger: Sendable, Equatable {
    /// Every decision ever recorded, oldest grant first. Withdrawn records stay.
    public private(set) var records: [HealthDataConsent]

    public init(records: [HealthDataConsent] = []) {
        self.records = records.sorted {
            $0.grantedAt == $1.grantedAt
                ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                : $0.grantedAt < $1.grantedAt
        }
    }

    /// The record currently in force for a purpose, if any. At most one exists — `granting`
    /// refuses to create a second.
    public func recordInForce(for purpose: HealthDataConsent.Purpose) -> HealthDataConsent? {
        records.last { $0.purpose == purpose && $0.isInForce }
    }

    /// Every decision ever recorded for a purpose, including withdrawn ones.
    public func history(for purpose: HealthDataConsent.Purpose) -> [HealthDataConsent] {
        records.filter { $0.purpose == purpose }
    }

    /// Grant consent for one purpose against a specific notice version. Appends a new record;
    /// nothing existing is touched.
    ///
    /// Re-granting after a withdrawal is legal and produces a **new** record with its own
    /// `grantedAt` and `noticeVersion` — the withdrawn record remains as evidence of the
    /// earlier period.
    public func granting(
        _ purpose: HealthDataConsent.Purpose,
        noticeVersion: PrivacyNoticeVersion,
        at now: Date
    ) throws -> (ledger: HealthDataConsentLedger, record: HealthDataConsent) {
        if recordInForce(for: purpose) != nil {
            throw HealthDataConsentError.alreadyGranted(purpose)
        }
        let record = HealthDataConsent(purpose: purpose, noticeVersion: noticeVersion, grantedAt: now)
        return (HealthDataConsentLedger(records: records + [record]), record)
    }

    /// Withdraw consent for one purpose. Closes the in-force record; the returned ledger has
    /// the same record count and the same ids — by construction, since this maps over the
    /// existing array rather than rebuilding it.
    public func withdrawing(
        _ purpose: HealthDataConsent.Purpose,
        at now: Date
    ) throws -> (ledger: HealthDataConsentLedger, record: HealthDataConsent) {
        guard let target = recordInForce(for: purpose) else {
            throw HealthDataConsentError.noConsentInForce(purpose)
        }
        var closed = target
        try closed.withdraw(at: now)
        let updated = records.map { $0.id == closed.id ? closed : $0 }
        return (HealthDataConsentLedger(records: updated), closed)
    }

    /// Withdrawing one purpose never touches another (unbundled by construction — purposes
    /// live on separate records). Exposed for call sites that want the whole picture at once.
    public var decisionsByPurpose: [HealthDataConsent.Purpose: HealthDataCollectionDecision] {
        var result: [HealthDataConsent.Purpose: HealthDataCollectionDecision] = [:]
        for purpose in HealthDataConsent.Purpose.allCases {
            result[purpose] = HealthDataConsentPolicy.decision(for: purpose, in: self)
        }
        return result
    }
}

// MARK: - Policy

/// The answer to "may the app collect/record health data for this purpose right now?".
public enum HealthDataCollectionDecision: Sendable, Equatable {
    /// A record is in force. Carries the evidence so the UI can state what was agreed to.
    case permitted(noticeVersion: PrivacyNoticeVersion, grantedAt: Date)
    /// No decision has ever been recorded for this purpose — ask.
    case neverGranted
    /// Consent was given and later withdrawn. Future collection stops; nothing recorded before
    /// the withdrawal is affected.
    case withdrawn(at: Date)

    public var isPermitted: Bool {
        if case .permitted = self { return true }
        return false
    }
}

/// Pure policy (no I/O, no clock): given the ledger, may we collect for this purpose?
///
/// This is the single answer every gate must ask. Views, view-models and services all route
/// through it so the rule cannot drift between surfaces (ADR-0004's "views never hand-roll
/// checks", applied to consent).
public enum HealthDataConsentPolicy {
    public static func decision(
        for purpose: HealthDataConsent.Purpose,
        in ledger: HealthDataConsentLedger
    ) -> HealthDataCollectionDecision {
        if let inForce = ledger.recordInForce(for: purpose) {
            return .permitted(noticeVersion: inForce.noticeVersion, grantedAt: inForce.grantedAt)
        }
        let history = ledger.history(for: purpose)
        if let latestWithdrawal = history.compactMap(\.withdrawnAt).max() {
            return .withdrawn(at: latestWithdrawal)
        }
        return .neverGranted
    }

    public static func mayCollect(
        _ purpose: HealthDataConsent.Purpose,
        given ledger: HealthDataConsentLedger
    ) -> Bool {
        decision(for: purpose, in: ledger).isPermitted
    }
}
