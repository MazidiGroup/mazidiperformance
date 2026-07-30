import SwiftUI
import UIKit
import MazidiDomain

/// Active workout — one-handed gym mode (panels 3d / 7g). Shows the current exercise with a
/// live demonstration (only the opened exercise animates), type-aware set entry, the rest
/// timer, swap, and pause/exit. It renders domain truth and forwards intents to the model;
/// it holds no workout state itself.
struct ActiveWorkoutView: View {
    @Bindable var model: ClientWorkoutModel
    let onExit: () -> Void
    let onCompleted: () -> Void
    let onReviewConsent: () -> Void

    @State private var showSwap = false
    @State private var showPause = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var exercise: AssignedExercise? { model.selectedExercise }
    private var exerciseIndex: Int {
        guard let e = exercise else { return 0 }
        return model.orderedExercises.firstIndex { $0.id == e.id } ?? 0
    }

    var body: some View {
        Group {
            if let exercise {
                content(for: exercise)
            } else {
                MessageState(systemImage: "questionmark.circle", title: "No exercise selected")
            }
        }
        .background(MazidiColor.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    // Pausing the session and presenting the options is one intent (5a):
                    // the workout is paused, then Resume / Keep / Discard are offered.
                    Task { await model.pause(); showPause = true }
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
                .accessibilityIdentifier(A11yID.activePauseButton)
            }
            ToolbarItem(placement: .principal) { SyncStatusView(sync: model.sync) }
        }
        .sheet(isPresented: $showSwap) {
            if let exercise { SwapExerciseSheet(model: model, exercise: exercise) }
        }
        .sheet(isPresented: $showPause) {
            PauseExitSheet(model: model, onLeave: onExit)
        }
        .alert("Heads up", isPresented: Binding(
            get: { model.transientError != nil },
            set: { if !$0 { model.transientError = nil } }
        )) {
            Button("OK", role: .cancel) { model.transientError = nil }
        } message: {
            Text(model.transientError ?? "")
        }
        .onChange(of: model.restFinishedTick) { _, _ in
            announce("Rest complete. Next set.")
        }
        .onChange(of: model.transientError) { _, message in
            if let message { announce(message) }
        }
    }

    @ViewBuilder private func content(for exercise: AssignedExercise) -> some View {
        // Copy, name and badge must describe the exercise actually being performed —
        // after an approved swap that is the alternative, not the assigned slug (4b/7h).
        let performed = model.performedSlug(for: exercise)
        let isSwapped = performed != exercise.slug
        let content = model.content(for: performed)
        let name = content?.displayName ?? performed.rawValue
        let recorded = model.setsRecorded(for: exercise)
        let total = exercise.prescription.setCount
        let finished = recorded >= total

        ScrollView {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                Text("Exercise \(exerciseIndex + 1) of \(model.orderedExercises.count)")
                    .font(MazidiFont.caption)
                    .foregroundStyle(MazidiColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)

                ExerciseMediaView(
                    slug: performed,
                    displayName: name,
                    media: model.media,
                    isOpen: true
                )

                HStack {
                    Text(name)
                        .font(MazidiFont.screenTitle)
                        .foregroundStyle(MazidiColor.text)
                        .accessibilityIdentifier(A11yID.activeExerciseTitle)
                    Spacer()
                    if !exercise.approvedAlternatives.isEmpty {
                        Button {
                            showSwap = true
                        } label: {
                            Label("Swap", systemImage: "arrow.triangle.2.circlepath")
                                .font(MazidiFont.callout)
                        }
                        .accessibilityIdentifier(A11yID.activeSwapButton)
                    }
                }

                if content?.contentStatus == .draftRequiresHumanReview {
                    DraftBadge()
                }
                if isSwapped {
                    let assignedName = model.content(for: exercise.slug)?.displayName ?? exercise.slug.rawValue
                    StatusBadge(kind: .info, label: "Swapped from \(assignedName)", systemImage: "arrow.triangle.2.circlepath")
                }

                progress(for: exercise, recorded: recorded, total: total)

                // The coach cue was written for the assigned exercise — don't show it
                // under a swapped alternative it may not apply to.
                if !isSwapped, let cue = exercise.coachCue {
                    Text(cue)
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)
                }

                recordedSets(exercise)

                heldEntryNotice

                // Rest timer takes over between sets; otherwise the set-entry form (unless done).
                if model.phase == .paused {
                    pausedBanner
                } else if model.restTimer != nil {
                    RestTimerView(model: model)
                } else if finished {
                    finishedNotice
                } else if !model.mayCollect(.performanceRecording) {
                    // Consent gate (ADR-0013): recording is not permitted, so the form that
                    // collects is not offered at all. The workout itself stays usable.
                    consentRequiredNotice
                } else {
                    SetEntryForm(
                        exercise: exercise,
                        setNumber: recorded + 1,
                        // Effort ratings are a separate consented purpose; the control is
                        // absent — not silently ignored — when that consent is not in force.
                        allowsEffortRating: model.mayCollect(.perceivedExertionRecording),
                        onRequestEffortRating: onReviewConsent
                    ) { value, rpe in
                        Task { await model.logSet(for: exercise, value: value, rpe: rpe) }
                    }
                    .padding(.top, 4)
                }

                navigation(finished: finished)
            }
            .padding(MazidiMetric.screenPadding)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func progress(for exercise: AssignedExercise, recorded: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(PrescriptionFormat.summary(exercise.prescription))
                    .font(MazidiFont.bodyEmphasis)
                    .foregroundStyle(MazidiColor.text)
                Spacer()
                Text("Set \(min(recorded + (recorded < total ? 1 : 0), total)) of \(total)")
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.textSecondary)
            }
            ProgressView(value: Double(recorded), total: Double(max(total, 1)))
                .tint(MazidiColor.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(recorded) of \(total) sets recorded")
    }

    @ViewBuilder private func recordedSets(_ exercise: AssignedExercise) -> some View {
        let entries = model.entries(for: exercise)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MazidiColor.successText)
                            .accessibilityHidden(true)
                        Text("Set \(entry.setIndex + 1)")
                            .font(MazidiFont.callout)
                            .foregroundStyle(MazidiColor.textSecondary)
                        Spacer()
                        Text(PrescriptionFormat.summary(entry.value, rpe: entry.rpe))
                            .font(MazidiFont.bodyEmphasis)
                            .foregroundStyle(MazidiColor.text)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Set \(entry.setIndex + 1) recorded")
                    .accessibilityValue(PrescriptionFormat.summary(entry.value, rpe: entry.rpe))
                    .accessibilityIdentifier("\(A11yID.setEntryRow).\(index)")
                    if entry.id != entries.last?.id { Divider().overlay(MazidiColor.hairline) }
                }
            }
            .padding(MazidiMetric.cardPadding)
            .background(MazidiColor.surface, in: RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous))
        }
    }

    private var pausedBanner: some View {
        MazidiCard {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                StatusBadge(kind: .warning, label: "Paused", systemImage: "pause.circle")
                Text("Workout paused. Nothing is lost — resume when you're ready.")
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.text)
                Button("Resume workout") {
                    Task { await model.resumeWorkout() }
                }
                .buttonStyle(.mazidiPrimary)
                .accessibilityIdentifier(A11yID.activeInlineResume)
            }
        }
    }

    /// Recording is not permitted for want of consent. Says so plainly and offers the choice
    /// — never a dead end, never a silent no-op.
    private var consentRequiredNotice: some View {
        MazidiCard {
            VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                StatusBadge(kind: .info, label: "Not recording", systemImage: "hand.raised")
                // Identifiers go on leaf views, never on the card — an accessibility modifier
                // on a container collapses it into one element and hides the button inside.
                Text("You haven't agreed to the app recording your training, so sets aren't being saved. You can still follow the workout.")
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(A11yID.consentRequiredNotice)
                Button("Review your choices", action: onReviewConsent)
                    .buttonStyle(.mazidiPrimary)
                    .accessibilityIdentifier(A11yID.consentOpenButton)
            }
        }
    }

    /// A set the consent gate refused. It is held, not dropped — the client is told exactly
    /// what was not recorded and chooses what happens to it.
    @ViewBuilder private var heldEntryNotice: some View {
        if let held = model.heldSetEntry {
            MazidiCard {
                VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                    StatusBadge(kind: .warning, label: "Not saved yet", systemImage: "tray")
                    Text("This set wasn't saved: \(PrescriptionFormat.summary(held.value, rpe: held.rpe)). It needs your agreement to “\(HealthPrivacyNotice.title(for: held.blockedBy))”.")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(A11yID.heldEntryNotice)
                    Button("Review your choices", action: onReviewConsent)
                        .buttonStyle(.mazidiSecondary)
                        .accessibilityIdentifier(A11yID.consentOpenButton)
                    if held.blockedBy == .perceivedExertionRecording {
                        Button("Save without the effort rating") {
                            Task { await model.recordHeldEntryWithoutEffortRating() }
                        }
                        .buttonStyle(.mazidiSecondary)
                        .accessibilityIdentifier(A11yID.heldEntryLogWithoutEffortButton)
                    }
                    Button("Discard this set") { model.discardHeldSetEntry() }
                        .buttonStyle(.mazidiSecondary)
                        .accessibilityIdentifier(A11yID.heldEntryDiscardButton)
                }
            }
        }
    }

    private var finishedNotice: some View {
        MazidiCard {
            HStack(spacing: MazidiMetric.tightSpacing) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(MazidiColor.successText)
                    .accessibilityHidden(true)
                Text("All sets recorded for this exercise.")
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.text)
            }
        }
    }

    private func navigation(finished: Bool) -> some View {
        VStack(spacing: MazidiMetric.stackSpacing) {
            HStack(spacing: MazidiMetric.stackSpacing) {
                Button {
                    model.goToPreviousExercise()
                } label: {
                    Label("Previous", systemImage: "chevron.left").frame(maxWidth: .infinity, minHeight: MazidiMetric.minTarget)
                }
                .buttonStyle(.mazidiSecondary)
                .disabled(exerciseIndex == 0)
                .accessibilityIdentifier(A11yID.activePreviousExercise)

                Button {
                    model.advanceToNextExercise()
                } label: {
                    Label("Next", systemImage: "chevron.right").frame(maxWidth: .infinity, minHeight: MazidiMetric.minTarget)
                }
                .buttonStyle(.mazidiSecondary)
                .disabled(exerciseIndex >= model.orderedExercises.count - 1)
                .accessibilityIdentifier(A11yID.activeNextExercise)
            }

            Button {
                Task {
                    await model.complete()
                    if case .finished = model.today { onCompleted() }
                }
            } label: {
                Text(model.allPrescribedSetsRecorded ? "Complete workout" : "Finish early")
            }
            .buttonStyle(.mazidiPrimary)
            .accessibilityIdentifier(A11yID.activeCompleteButton)
        }
        .padding(.top, 4)
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
