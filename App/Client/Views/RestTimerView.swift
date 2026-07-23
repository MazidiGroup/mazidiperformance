import SwiftUI

/// Rest timer between sets (panel 4a). Accessibility rules (14f):
/// - Under **Reduce Motion** the animated ring is suppressed; a numeric countdown remains.
/// - The value uses monospaced digits so it never reflows tick-to-tick.
/// - Controls are ≥44pt and fully labelled; the countdown exposes a live text value.
struct RestTimerView: View {
    @Bindable var model: ClientWorkoutModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var duration: Int { max(model.restTimer?.durationSeconds ?? 1, 1) }
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return Double(duration - model.restRemaining) / Double(duration)
    }

    var body: some View {
        MazidiCard {
            HStack(spacing: MazidiMetric.stackSpacing) {
                countdown
                controls
            }
        }
        // The whole card announces the live remaining time to VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rest timer")
    }

    private var countdown: some View {
        ZStack {
            if !reduceMotion {
                Circle().stroke(MazidiColor.hairline, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(progress, 1))
                    .stroke(MazidiColor.primary, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
            } else {
                Circle().stroke(MazidiColor.hairline, lineWidth: 6)
            }
            Text("\(model.restRemaining)")
                .font(MazidiFont.timerDisplay)
                .foregroundStyle(MazidiColor.text)
        }
        .frame(width: 92, height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rest remaining")
        .accessibilityValue("\(model.restRemaining) seconds")
        .accessibilityIdentifier(A11yID.restTimerValue)
    }

    private var controls: some View {
        VStack(spacing: MazidiMetric.tightSpacing) {
            Button {
                model.extendRest(by: 30)
            } label: {
                Label("+30s", systemImage: "goforward.30")
            }
            .buttonStyle(.mazidiSecondary)
            .accessibilityIdentifier(A11yID.restTimerAddButton)
            .accessibilityLabel("Add 30 seconds")

            HStack(spacing: MazidiMetric.tightSpacing) {
                Button {
                    model.toggleRestPause()
                } label: {
                    Label(model.restIsPaused ? "Resume" : "Pause",
                          systemImage: model.restIsPaused ? "play.fill" : "pause.fill")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: MazidiMetric.minTarget, minHeight: MazidiMetric.minTarget)
                }
                .buttonStyle(.mazidiSecondary)
                .accessibilityIdentifier(A11yID.restTimerPauseButton)
                .accessibilityLabel(model.restIsPaused ? "Resume rest" : "Pause rest")

                Button {
                    model.skipRest()
                } label: {
                    Text("Skip")
                        .frame(minWidth: MazidiMetric.minTarget, minHeight: MazidiMetric.minTarget)
                }
                .buttonStyle(.mazidiSecondary)
                .accessibilityIdentifier(A11yID.restTimerSkipButton)
                .accessibilityLabel("Skip rest")
            }
        }
    }
}
