import SwiftUI
import MazidiDomain

/// Workout overview before starting (panels 3c / 7f). Sections (warm-up / main / cool-down)
/// list each exercise with its poster, type-aware prescription and swap availability. Tapping
/// a row opens the exercise detail; the primary action begins the session.
struct WorkoutOverviewView: View {
    @Bindable var model: ClientWorkoutModel
    let onBegin: () -> Void
    let onOpenExercise: (AssignedExercise) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                ForEach(model.sectionGroups) { group in
                    SectionHeader(title: sectionTitle(group.section))
                    ForEach(group.exercises) { exercise in
                        row(exercise)
                    }
                }
            }
            .padding(MazidiMetric.screenPadding)
        }
        .background(MazidiColor.background)
        .navigationTitle(model.workout.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button("Begin workout", action: onBegin)
                .buttonStyle(.mazidiPrimary)
                .padding(MazidiMetric.screenPadding)
                .background(.bar)
                .accessibilityIdentifier(A11yID.overviewBeginButton)
        }
    }

    private func row(_ exercise: AssignedExercise) -> some View {
        let content = model.content(for: exercise.slug)
        let name = content?.displayName ?? exercise.slug.rawValue
        return Button {
            onOpenExercise(exercise)
        } label: {
            HStack(spacing: MazidiMetric.stackSpacing) {
                ExercisePosterThumbnail(slug: exercise.slug, displayName: name, media: model.media)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(MazidiFont.bodyEmphasis)
                        .foregroundStyle(MazidiColor.text)
                    Text(PrescriptionFormat.summary(exercise.prescription))
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)
                    HStack(spacing: 6) {
                        if !exercise.approvedAlternatives.isEmpty {
                            StatusBadge(kind: .info, label: "Swap available", systemImage: "arrow.triangle.2.circlepath")
                        }
                        if content?.contentStatus == .draftRequiresHumanReview {
                            StatusBadge(kind: .warning, label: "Draft copy", systemImage: "pencil")
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(MazidiColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(MazidiMetric.cardPadding)
            .frame(minHeight: MazidiMetric.minTarget)
            .background(MazidiColor.surface, in: RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous)
                    .strokeBorder(MazidiColor.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(A11yID.overviewExerciseRow).\(exercise.slug.rawValue)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(PrescriptionFormat.accessibleSummary(exercise.prescription))
        .accessibilityHint("Opens exercise detail")
        .accessibilityAddTraits(.isButton)
    }

    private func sectionTitle(_ section: AssignedWorkout.Section) -> String {
        switch section {
        case .warmUp: return "Warm-up"
        case .main: return "Main"
        case .coolDown: return "Cool-down"
        }
    }
}
