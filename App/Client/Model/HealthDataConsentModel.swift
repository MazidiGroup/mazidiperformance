import Foundation
import Observation
import MazidiDomain
import MazidiServices

/// View-model for the health-data consent screen and the privacy (withdrawal) surface.
///
/// It is a thin adapter over `HealthDataConsentService`: every rule — what counts as consent,
/// what withdrawal means, whether collection is permitted — lives in the domain policy and the
/// service. This type only mirrors that truth for SwiftUI and carries the user's *unsaved*
/// tick-box selections.
@MainActor
@Observable
final class HealthDataConsentModel {
    /// Current decision per purpose, as the domain policy sees it.
    private(set) var decisions: [HealthDataConsent.Purpose: HealthDataCollectionDecision] = [:]
    /// The append-only record history — the evidential trail, shown so the client can see
    /// exactly what they agreed to and when.
    private(set) var history: [HealthDataConsent] = []
    private(set) var isBusy = false
    var errorMessage: String?

    /// Unsaved tick-box state for the consent screen. Deliberately starts **empty**: an absent
    /// entry reads as unticked, so there is no code path that can present a pre-ticked box.
    private var selections: [HealthDataConsent.Purpose: Bool] = [:]

    private let env: ClientEnvironment

    init(environment: ClientEnvironment) {
        self.env = environment
    }

    // MARK: Reading

    /// Purposes in the order they are presented. Stable, so VoiceOver order matches visual
    /// order on every launch.
    var orderedPurposes: [HealthDataConsent.Purpose] { HealthDataConsent.Purpose.allCases }

    func decision(for purpose: HealthDataConsent.Purpose) -> HealthDataCollectionDecision {
        decisions[purpose] ?? .neverGranted
    }

    func isPermitted(_ purpose: HealthDataConsent.Purpose) -> Bool {
        decision(for: purpose).isPermitted
    }

    /// Purposes still to be decided — the ones the consent screen offers.
    var undecidedPurposes: [HealthDataConsent.Purpose] {
        orderedPurposes.filter { !isPermitted($0) }
    }

    var hasAnyDecisionOnRecord: Bool { !history.isEmpty }

    func isSelected(_ purpose: HealthDataConsent.Purpose) -> Bool { selections[purpose] ?? false }

    func setSelected(_ purpose: HealthDataConsent.Purpose, _ value: Bool) {
        selections[purpose] = value
    }

    var selectedPurposes: [HealthDataConsent.Purpose] {
        orderedPurposes.filter { isSelected($0) }
    }

    func load() async {
        decisions = await env.consentDecisions()
        history = ((try? await env.consent.ledger().records) ?? [])
    }

    // MARK: Writing

    /// Record the ticked purposes — and only those. Untouched purposes stay undecided; no
    /// consent is inferred from silence.
    @discardableResult
    func saveSelections() async -> Bool {
        let purposes = selectedPurposes
        guard !purposes.isEmpty else { return true }  // "none of these" is a valid outcome
        return await run { try await self.env.consent.grant(purposes, noticeVersion: HealthPrivacyNotice.version) }
    }

    /// Withdraw one purpose. Stops future collection for it; nothing already recorded changes.
    @discardableResult
    func withdraw(_ purpose: HealthDataConsent.Purpose) async -> Bool {
        await run { try await self.env.consent.withdraw(purpose) }
    }

    private func run(_ operation: @escaping () async throws -> HealthDataConsentLedger) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await operation()
            selections = [:]
            await load()
            return true
        } catch {
            errorMessage = "That choice couldn't be saved on this phone. Nothing was changed — please try again."
            await load()
            return false
        }
    }
}
