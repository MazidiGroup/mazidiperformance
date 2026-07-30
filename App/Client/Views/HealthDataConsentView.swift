import SwiftUI
import MazidiDomain

/// Health-data consent screen (ADR-0013). Presented **before** the app records anything about
/// a client's training.
///
/// Rules this screen exists to keep, and how it keeps them:
/// - **Unbundled** — one control per purpose, each with its own explanation and its own
///   consequence-of-declining line. Nothing here agrees to more than one purpose at a time.
/// - **Nothing pre-ticked** — the model's selection map starts empty and an absent entry reads
///   as unticked, so there is no code path that can present a ticked box.
/// - **Not a condition of using the app** — "Not now" is a first-class exit, and every purpose
///   states plainly what still works if you decline.
/// - **Consent is to a specific text** — the notice is on this screen and its version is
///   recorded with the decision.
struct HealthDataConsentView: View {
    @Bindable var model: HealthDataConsentModel
    /// Called when the client has finished with this screen (saved or declined), so the
    /// workout model can re-read the ledger and act on anything it was holding.
    let onFinished: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showNotice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                header
                if !HealthPrivacyNotice.isLegallyApproved { draftNotice }
                Text(HealthPrivacyNotice.screenIntro)
                    .font(MazidiFont.body)
                    .foregroundStyle(MazidiColor.text)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(model.orderedPurposes, id: \.self) { purpose in
                    purposeCard(purpose)
                }

                noticeDisclosure
                actions

                Text("You can change any of these later under Privacy.")
                    .font(MazidiFont.caption)
                    .foregroundStyle(MazidiColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(MazidiMetric.screenPadding)
        }
        .background(MazidiColor.background)
        .navigationTitle("Your choices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .alert("Couldn't save", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        Text("Your health data choices")
            .font(MazidiFont.screenTitle)
            .foregroundStyle(MazidiColor.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    /// The notice wording has not been through legal review yet (ADR-0013 Phase 0 gate 4).
    /// Labelled, never hidden — the same honesty rule the draft exercise copy follows.
    private var draftNotice: some View {
        MazidiCard {
            VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                StatusBadge(kind: .warning, label: "DRAFT WORDING · PENDING REVIEW",
                            systemImage: "pencil.and.outline")
                Text("The wording on this screen is still being reviewed. Your choices are recorded against version \(HealthPrivacyNotice.version.rawValue), and you'll be asked again if the wording changes.")
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func purposeCard(_ purpose: HealthDataConsent.Purpose) -> some View {
        let title = HealthPrivacyNotice.title(for: purpose)
        MazidiCard {
            VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                if model.isPermitted(purpose) {
                    // Already decided — shown for completeness, not re-asked. Colour is never
                    // the only signal: badge carries icon + text.
                    StatusBadge(kind: .success, label: "Already on", systemImage: "checkmark.circle")
                    Text(title)
                        .font(MazidiFont.bodyEmphasis)
                        .foregroundStyle(MazidiColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(HealthPrivacyNotice.explanation(for: purpose))
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle(isOn: Binding(
                        get: { model.isSelected(purpose) },
                        set: { model.setSelected(purpose, $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(MazidiFont.bodyEmphasis)
                                .foregroundStyle(MazidiColor.text)
                            Text(HealthPrivacyNotice.explanation(for: purpose))
                                .font(MazidiFont.callout)
                                .foregroundStyle(MazidiColor.textSecondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .tint(MazidiColor.primary)
                    .frame(minHeight: MazidiMetric.minTarget)
                    .accessibilityLabel(title)
                    .accessibilityHint(HealthPrivacyNotice.explanation(for: purpose))
                    .accessibilityIdentifier("\(A11yID.consentPurposeToggle).\(purpose.rawValue)")

                    Text("If you don't: \(HealthPrivacyNotice.consequenceOfDeclining(for: purpose))")
                        .font(MazidiFont.caption)
                        .foregroundStyle(MazidiColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var noticeDisclosure: some View {
        DisclosureGroup(isExpanded: $showNotice) {
            VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                Text(HealthPrivacyNotice.noticeSummary)
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Notice version \(HealthPrivacyNotice.version.rawValue)")
                    .font(MazidiFont.caption)
                    .foregroundStyle(MazidiColor.textTertiary)
            }
            .padding(.top, MazidiMetric.tightSpacing)
        } label: {
            // The identifier goes on the label, not the DisclosureGroup: an accessibility
            // modifier on the group would collapse it into one element, so VoiceOver could
            // never reach the notice text it reveals.
            Text("What happens to this information")
                .font(MazidiFont.bodyEmphasis)
                .foregroundStyle(MazidiColor.link)
                .frame(minHeight: MazidiMetric.minTarget, alignment: .leading)
                .accessibilityIdentifier(A11yID.consentNoticeDisclosure)
        }
        .tint(MazidiColor.link)
    }

    private var actions: some View {
        VStack(spacing: MazidiMetric.stackSpacing) {
            Button("Save my choices") {
                Task {
                    await model.saveSelections()
                    onFinished()
                }
            }
            .buttonStyle(.mazidiPrimary)
            .disabled(model.isBusy)
            .accessibilityIdentifier(A11yID.consentSaveButton)

            Button("Not now", action: onFinished)
                .buttonStyle(.mazidiSecondary)
                .accessibilityIdentifier(A11yID.consentNotNowButton)
                .accessibilityHint("Continue without agreeing. The app won't record this information.")
        }
        .padding(.top, 4)
    }
}
