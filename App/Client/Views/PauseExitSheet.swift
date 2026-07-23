import SwiftUI

/// Pause / exit options (panels 5a / 5g) — "nothing lost". Recorded work is always kept;
/// the client chooses to resume now, keep the session for later (exit → resumable from
/// Today, 5b), or explicitly discard it. Discard still keeps recorded sets as readable
/// history in the domain; it only stops further writing.
struct PauseExitSheet: View {
    @Bindable var model: ClientWorkoutModel
    @Environment(\.dismiss) private var dismiss
    /// Called after a choice that should leave the active workout (exit/discard).
    let onLeave: () -> Void

    @State private var confirmingDiscard = false

    private var recordedCount: Int { model.session?.setEntries.count ?? 0 }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                MazidiCard {
                    HStack(spacing: MazidiMetric.tightSpacing) {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(MazidiColor.successText)
                            .accessibilityHidden(true)
                        Text(recordedCount == 0
                             ? "Nothing to lose yet — you can leave and pick this up later."
                             : "\(recordedCount) set\(recordedCount == 1 ? "" : "s") saved on this phone. Nothing is lost if you stop now.")
                            .font(MazidiFont.callout)
                            .foregroundStyle(MazidiColor.text)
                    }
                }

                Button("Resume workout") {
                    Task { await model.resumeWorkout(); dismiss() }
                }
                .buttonStyle(.mazidiPrimary)
                .accessibilityIdentifier(A11yID.pauseResumeButton)

                Button("Keep for later") {
                    Task { await model.exitKeepingProgress(); dismiss(); onLeave() }
                }
                .buttonStyle(.mazidiSecondary)
                .accessibilityIdentifier(A11yID.pauseExitKeepButton)

                Button(role: .destructive) {
                    confirmingDiscard = true
                } label: {
                    Text("Discard workout")
                        .frame(maxWidth: .infinity, minHeight: MazidiMetric.minTarget)
                        .foregroundStyle(MazidiColor.dangerText)
                }
                .accessibilityIdentifier(A11yID.pauseDiscardButton)

                Spacer()
            }
            .padding(MazidiMetric.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MazidiColor.background)
            .navigationTitle("Pause workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .confirmationDialog(
                "Discard this workout? Your recorded sets stay in your history, but the session ends.",
                isPresented: $confirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard workout", role: .destructive) {
                    Task { await model.discard(); dismiss(); onLeave() }
                }
                Button("Keep going", role: .cancel) {}
            }
        }
        .presentationDetents([.medium])
    }
}
