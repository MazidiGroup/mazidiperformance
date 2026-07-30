import SwiftUI
import MazidiDomain

/// Client Today (panel 3a): one clear next action. Depending on domain truth this offers
/// today's assigned workout, a resumable unfinished session (5b), or a completed summary.
struct ClientHomeView: View {
    @Bindable var model: ClientWorkoutModel
    let onViewWorkout: () -> Void
    let onResume: () -> Void
    let onViewSummary: () -> Void
    let onReviewConsent: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                header

                storeRecoveryNotice

                consentNotice

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
        // Title and sync badge restack at accessibility sizes so the badge keeps a full
        // line instead of wrapping mid-word beside the title (14c).
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: MazidiMetric.tightSpacing))
            : AnyLayout(HStackLayout())
        return layout {
            Text("Your session")
                .font(MazidiFont.screenTitle)
                .foregroundStyle(MazidiColor.text)
                .accessibilityAddTraits(.isHeader)
            if !typeSize.isAccessibilitySize { Spacer() }
            SyncStatusView(sync: model.sync)
        }
    }

    /// Honest storage-recovery states (MIGRATIONS.md): a fresh database after quarantine
    /// or an in-memory fallback must never present as a normal empty Today. Colour is
    /// never the only signal — icon + label + text. Retrieval of a quarantined file waits
    /// on the support/export flow (KNOWN_ISSUES L5).
    @ViewBuilder private var storeRecoveryNotice: some View {
        switch model.storeHealth {
        case .durable, .intentionallyEphemeral:
            EmptyView()
        case .recoveredAfterQuarantine:
            MazidiCard {
                VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                    StatusBadge(kind: .warning, label: "Storage recovered", systemImage: "externaldrive.badge.exclamationmark")
                    Text("Your previous workout data couldn't be read, so it was set aside safely — nothing was deleted — and you're starting with fresh storage. Support can help recover the saved file.")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.text)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("store_recovery_notice")
        case .ephemeralFallback:
            MazidiCard {
                VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                    StatusBadge(kind: .danger, label: "Storage unavailable", systemImage: "externaldrive.badge.xmark")
                    Text("Workout storage couldn't be opened. You can still train, but workouts recorded right now won't survive closing the app.")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.text)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("store_recovery_notice")
        }
    }

    /// Consent is asked for **before** anything is recorded (ADR-0013), so Today surfaces the
    /// choice rather than letting the client discover it mid-set. Not a blocker: the workout
    /// is still viewable, and declining is a stated option on the consent screen itself.
    @ViewBuilder private var consentNotice: some View {
        if !model.mayCollect(.performanceRecording) {
            MazidiCard {
                VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                    StatusBadge(kind: .info, label: "Before you record", systemImage: "hand.raised")
                    Text("Recording your training is your choice. Have a look at what the app would record and decide — you can pick each item separately.")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Review your choices", action: onReviewConsent)
                        .buttonStyle(.mazidiSecondary)
                        .accessibilityIdentifier(A11yID.consentOpenButton)
                }
            }
            .accessibilityIdentifier(A11yID.consentTodayCard)
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
            if model.pendingAssignment != nil {
                StatusBadge(kind: .info, label: "Assigned by your coach", systemImage: "person.crop.circle.badge.checkmark")
                    .accessibilityIdentifier("today_assigned_badge")
            }
            WorkoutSummaryCard(model: model)
                .accessibilityIdentifier(A11yID.todayWorkoutCard)
            Button("View workout", action: onViewWorkout)
                .buttonStyle(.mazidiPrimary)
                .accessibilityIdentifier(A11yID.todayStartWorkout)
            #if DEBUG
            DevConnectivityToggle(model: model)
                .padding(.top, 4)
            #endif
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
            #if DEBUG
            DevConnectivityToggle(model: model)
                .padding(.top, 4)
            #endif
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
