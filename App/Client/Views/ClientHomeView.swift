import SwiftUI
import MazidiDomain

/// Client Today (panel 3a): one clear next action. Depending on domain truth this offers
/// today's assigned workout, a resumable unfinished session (5b), or a completed summary.
struct ClientHomeView: View {
    @Bindable var model: ClientWorkoutModel
    let onViewWorkout: () -> Void
    let onResume: () -> Void
    let onViewSummary: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                header

                switch model.today {
                case .loading:
                    loading
                case .ready:
                    assignedCard
                case .resume:
                    resumeCard
                case .finished:
                    finishedCard
                case let .failed(message):
                    MessageState(systemImage: "wifi.exclamationmark",
                                 title: "Couldn't load today",
                                 message: message,
                                 retry: { Task { await model.loadToday() } })
                }
            }
            .padding(MazidiMetric.screenPadding)
        }
        .background(MazidiColor.background)
        .navigationTitle("Today")
    }

    private var header: some View {
        HStack {
            Text("Your session")
                .font(MazidiFont.screenTitle)
                .foregroundStyle(MazidiColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            SyncStatusView(sync: model.sync)
        }
    }

    private var loading: some View {
        MazidiCard {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                SkeletonBlock(height: 160)
                SkeletonBlock(height: 20)
                SkeletonBlock(height: 20)
            }
        }
        .accessibilityLabel("Loading today's workout")
    }

    private var assignedCard: some View {
        VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
            WorkoutSummaryCard(model: model)
                .accessibilityIdentifier(A11yID.todayWorkoutCard)
            Button("View workout", action: onViewWorkout)
                .buttonStyle(.mazidiPrimary)
                .accessibilityIdentifier(A11yID.todayStartWorkout)
            DevConnectivityToggle(model: model)
                .padding(.top, 4)
        }
    }

    private var resumeCard: some View {
        VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
            MazidiCard {
                VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                    StatusBadge(kind: .warning, label: "Unfinished", systemImage: "pause.circle")
                    Text(model.workout.title)
                        .font(MazidiFont.sectionTitle)
                        .foregroundStyle(MazidiColor.text)
                    Text("\(model.session?.setEntries.count ?? 0) set\(model.session?.setEntries.count == 1 ? "" : "s") saved. Pick up where you left off — nothing is lost.")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)
                }
            }
            Button("Resume workout", action: onResume)
                .buttonStyle(.mazidiPrimary)
                .accessibilityIdentifier(A11yID.todayResumeWorkout)
            DevConnectivityToggle(model: model)
                .padding(.top, 4)
        }
    }

    private var finishedCard: some View {
        VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
            MazidiCard {
                VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                    StatusBadge(kind: .success, label: "Completed", systemImage: "checkmark.seal")
                    Text(model.workout.title)
                        .font(MazidiFont.sectionTitle)
                        .foregroundStyle(MazidiColor.text)
                    Text("Great work. Your session is saved.")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)
                }
            }
            Button("View summary", action: onViewSummary)
                .buttonStyle(.mazidiSecondary)
        }
    }
}

/// Reusable summary of the assigned workout: title, section/exercise count, first poster.
struct WorkoutSummaryCard: View {
    @Bindable var model: ClientWorkoutModel

    private var exerciseCount: Int { model.orderedExercises.count }

    var body: some View {
        MazidiCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let first = model.orderedExercises.first {
                    ExerciseMediaView(
                        slug: model.performedSlug(for: first),
                        displayName: model.content(for: first.slug)?.displayName ?? first.slug.rawValue,
                        media: model.media,
                        isOpen: false
                    )
                    .padding(MazidiMetric.cardPadding)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.workout.title)
                        .font(MazidiFont.sectionTitle)
                        .foregroundStyle(MazidiColor.text)
                    Text("\(exerciseCount) exercises · \(model.sectionGroups.count) sections")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)
                }
                .padding([.horizontal, .bottom], MazidiMetric.cardPadding)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.workout.title), \(exerciseCount) exercises")
    }
}
