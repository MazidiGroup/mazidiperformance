import SwiftUI
import MazidiDomain

/// Privacy surface — where a client sees and **withdraws** health-data consent (ADR-0013).
///
/// Art. 7(3) requires withdrawal to be as easy as giving consent, so it lives in the app one
/// tap from Today, not behind an email to support. The copy is deliberately literal about what
/// withdrawal does and does not do: it stops future recording or sending, and it does not
/// delete anything already recorded (CLAUDE.md — sharing off never deletes past content). A
/// control that implied deletion while data was retained would be a false statement to the
/// client.
struct HealthDataPrivacyView: View {
    @Bindable var model: HealthDataConsentModel
    /// Route to the consent screen — turning a purpose back on must show the notice again,
    /// because consent is consent to a specific text.
    let onGrant: () -> Void

    @State private var pendingWithdrawal: HealthDataConsent.Purpose?
    @State private var showHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                Text("What the app records")
                    .font(MazidiFont.screenTitle)
                    .foregroundStyle(MazidiColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                ForEach(model.orderedPurposes, id: \.self) { purpose in
                    purposeRow(purpose)
                }

                withdrawalExplainer
                historyDisclosure
            }
            .padding(MazidiMetric.screenPadding)
        }
        .background(MazidiColor.background)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .alert(
            pendingWithdrawal.map { "Turn off \(HealthPrivacyNotice.title(for: $0))?" } ?? "",
            isPresented: Binding(
                get: { pendingWithdrawal != nil },
                set: { if !$0 { pendingWithdrawal = nil } }
            )
        ) {
            Button("Turn off") {
                if let purpose = pendingWithdrawal {
                    Task { await model.withdraw(purpose) }
                }
                pendingWithdrawal = nil
            }
            .accessibilityIdentifier(A11yID.privacyWithdrawConfirmButton)
            Button("Cancel", role: .cancel) { pendingWithdrawal = nil }
        } message: {
            Text(pendingWithdrawal.map { HealthPrivacyNotice.withdrawalEffect(for: $0) } ?? "")
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Rows

    @ViewBuilder private func purposeRow(_ purpose: HealthDataConsent.Purpose) -> some View {
        let decision = model.decision(for: purpose)
        MazidiCard {
            VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                statusBadge(for: decision)
                Text(HealthPrivacyNotice.title(for: purpose))
                    .font(MazidiFont.bodyEmphasis)
                    .foregroundStyle(MazidiColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(HealthPrivacyNotice.explanation(for: purpose))
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Row identifier lives on a leaf: an accessibility modifier on the card would
                // collapse it into one element and hide the buttons below.
                Text(detail(for: decision))
                    .font(MazidiFont.caption)
                    .foregroundStyle(MazidiColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(A11yID.privacyPurposeRow).\(purpose.rawValue)")

                if decision.isPermitted {
                    Button("Turn off") { pendingWithdrawal = purpose }
                        .buttonStyle(.mazidiSecondary)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("\(A11yID.privacyWithdrawButton).\(purpose.rawValue)")
                        .accessibilityHint(HealthPrivacyNotice.withdrawalEffect(for: purpose))
                } else {
                    Button("Turn on", action: onGrant)
                        .buttonStyle(.mazidiSecondary)
                        .accessibilityIdentifier("\(A11yID.privacyGrantButton).\(purpose.rawValue)")
                        .accessibilityHint("Opens your choices, where the wording is shown again.")
                }
            }
        }
    }

    /// Status is never colour-only: every state pairs a tint with an icon and a text label.
    private func statusBadge(for decision: HealthDataCollectionDecision) -> some View {
        switch decision {
        case .permitted:
            return StatusBadge(kind: .success, label: "On", systemImage: "checkmark.circle")
        case .neverGranted:
            return StatusBadge(kind: .neutral, label: "Off", systemImage: "circle")
        case .withdrawn:
            return StatusBadge(kind: .neutral, label: "Turned off", systemImage: "minus.circle")
        }
    }

    private func detail(for decision: HealthDataCollectionDecision) -> String {
        switch decision {
        case let .permitted(noticeVersion, grantedAt):
            return "You agreed on \(Self.format(grantedAt)) · wording \(noticeVersion.rawValue)"
        case .neverGranted:
            return "You haven't agreed to this."
        case let .withdrawn(at):
            return "You turned this off on \(Self.format(at)). Anything recorded before then is still saved."
        }
    }

    private var withdrawalExplainer: some View {
        MazidiCard {
            VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                Text("Turning something off")
                    .font(MazidiFont.bodyEmphasis)
                    .foregroundStyle(MazidiColor.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Turning a choice off stops the app recording or sending anything new for that purpose. It does not delete what has already been recorded — your saved sessions stay on this phone. Deleting your data is a separate request.")
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var historyDisclosure: some View {
        DisclosureGroup(isExpanded: $showHistory) {
            VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                if model.history.isEmpty {
                    Text("No choices recorded yet.")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)
                } else {
                    ForEach(model.history) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(HealthPrivacyNotice.title(for: record.purpose))
                                .font(MazidiFont.callout)
                                .foregroundStyle(MazidiColor.text)
                            Text(Self.historyLine(record))
                                .font(MazidiFont.caption)
                                .foregroundStyle(MazidiColor.textTertiary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.top, MazidiMetric.tightSpacing)
        } label: {
            // Identifier on the label, not the group — see HealthDataConsentView.
            Text("Your choices so far")
                .font(MazidiFont.bodyEmphasis)
                .foregroundStyle(MazidiColor.link)
                .frame(minHeight: MazidiMetric.minTarget, alignment: .leading)
                .accessibilityIdentifier(A11yID.privacyHistoryDisclosure)
        }
        .tint(MazidiColor.link)
    }

    private static func historyLine(_ record: HealthDataConsent) -> String {
        let agreed = "Agreed \(format(record.grantedAt)) · wording \(record.noticeVersion.rawValue)"
        guard let withdrawnAt = record.withdrawnAt else { return agreed }
        return agreed + " · turned off \(format(withdrawnAt))"
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
