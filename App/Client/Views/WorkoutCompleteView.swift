import SwiftUI
import MazidiDomain

/// Workout complete (panel 3e) — a grown-up acknowledgement, not confetti. Summarises the
/// session honestly and reflects the sync state. Under Reduce Motion the success mark is
/// static (no animated celebration).
struct WorkoutCompleteView: View {
    @Bindable var model: ClientWorkoutModel
    let onDone: () -> Void

    private var session: WorkoutSession? { model.session }
    private var totalSets: Int { session?.setEntries.count ?? 0 }
    private var durationText: String {
        guard let s = session, let start = s.startedAt, let end = s.completedAt else { return "—" }
        let minutes = max(1, Int(end.timeIntervalSince(start) / 60))
        return "\(minutes) min"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                VStack(spacing: MazidiMetric.tightSpacing) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(MazidiColor.successText)
                        .accessibilityHidden(true)
                    Text("Workout complete")
                        .font(MazidiFont.screenTitle)
                        .foregroundStyle(MazidiColor.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.workout.title)
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, MazidiMetric.stackSpacing)

                MazidiCard {
                    VStack(spacing: MazidiMetric.stackSpacing) {
                        summaryRow("Exercises", "\(model.orderedExercises.count)")
                        Divider().overlay(MazidiColor.hairline)
                        summaryRow("Sets recorded", "\(totalSets)")
                        Divider().overlay(MazidiColor.hairline)
                        summaryRow("Time", durationText)
                    }
                }
                .accessibilityIdentifier(A11yID.completeSummary)

                HStack {
                    Spacer()
                    SyncStatusView(sync: model.sync)
                    Spacer()
                }

                Button("Done", action: onDone)
                    .buttonStyle(.mazidiPrimary)
                    .accessibilityIdentifier(A11yID.completeDoneButton)
            }
            .padding(MazidiMetric.screenPadding)
        }
        .background(MazidiColor.background)
        .navigationTitle("")
        .navigationBarBackButtonHidden(true)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(MazidiFont.body).foregroundStyle(MazidiColor.textSecondary)
            Spacer()
            Text(value).font(MazidiFont.metricValue).foregroundStyle(MazidiColor.text)
        }
        .accessibilityElement(children: .combine)
    }
}
