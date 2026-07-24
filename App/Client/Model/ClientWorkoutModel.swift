import Foundation
import Observation
import MazidiDomain
import MazidiFoundations
import MazidiServices
import MazidiSync

/// View-model for the Client workout flow. It is a thin UI adapter over
/// `WorkoutSessionService`/`WorkoutSession`: **all** state transitions, validation and
/// duplicate/ordering rules live in the domain and service. This type only mirrors the
/// domain's truth for SwiftUI, tracks which exercise is on screen, drives the rest-timer
/// tick, and translates the honest sync state for display.
@MainActor
@Observable
final class ClientWorkoutModel {
    // MARK: Presentation state (mirrors domain truth; never the source of it)

    enum TodayState: Equatable {
        case loading
        case ready(AssignedWorkout)      // nothing in progress — offer to begin
        case resume(WorkoutSession)      // an unfinished session exists (5b)
        case finished(WorkoutSession)    // most recent session completed
        case failed(String)
    }

    /// Honest sync presentation (4i). "Saved on this phone" is always true after a local
    /// write; higher states describe the queue truthfully and never claim synced early.
    enum SyncPresentation: Equatable {
        case synced
        case savedLocally(pending: Int)
        case syncing(remaining: Int)
        case waitingForConnectivity(pending: Int)
        case attentionNeeded(rejected: Int)
        case pausedAuthExpired(pending: Int)
    }

    private(set) var today: TodayState = .loading
    private(set) var session: WorkoutSession?
    private(set) var selectedExerciseID: Identifier<AssignedExercise>?
    private(set) var restTimer: RestTimer?
    private(set) var restRemaining: Int = 0
    private(set) var restFinishedTick: Int = 0        // bumps when a rest reaches zero (for announcements)
    private(set) var sync: SyncPresentation = .synced
    var transientError: String?                        // surfaced then cleared by the view

    // MARK: Dependencies

    private let env: ClientEnvironment
    private var service: WorkoutSessionService { env.service }
    private let clock: any AppClock
    private var restTicker: Task<Void, Never>?

    init(environment: ClientEnvironment) {
        self.env = environment
        self.clock = environment.clock
    }

    // MARK: Read-through helpers for views

    var workout: AssignedWorkout { session?.workout ?? env.assignedWorkout }
    var orderedExercises: [AssignedExercise] { workout.allExercises }
    var phase: WorkoutSession.Phase { session?.phase ?? .notStarted }
    var isActive: Bool { phase == .active }

    var selectedExercise: AssignedExercise? {
        guard let id = selectedExerciseID else { return orderedExercises.first }
        return orderedExercises.first { $0.id == id }
    }

    func content(for slug: ExerciseSlug) -> ExerciseContent? { env.content.content(for: slug) }
    var media: any MediaResolving { env.media }

    /// The slug actually being performed for an exercise (differs after an approved swap).
    func performedSlug(for exercise: AssignedExercise) -> ExerciseSlug {
        session?.swaps[exercise.id] ?? exercise.slug
    }

    func setsRecorded(for exercise: AssignedExercise) -> Int {
        session?.completedSetCount(for: exercise.id) ?? 0
    }

    func entries(for exercise: AssignedExercise) -> [SetEntry] {
        (session?.setEntries ?? []).filter { $0.exerciseID == exercise.id }.sorted { $0.setIndex < $1.setIndex }
    }

    func isFinished(_ exercise: AssignedExercise) -> Bool {
        setsRecorded(for: exercise) >= exercise.prescription.setCount
    }

    var allPrescribedSetsRecorded: Bool { session?.isEveryPrescribedSetRecorded ?? false }

    // MARK: Section grouping (warm-up / main / cool-down) for the overview

    struct SectionGroup: Identifiable {
        let section: AssignedWorkout.Section
        let exercises: [AssignedExercise]
        var id: String { section.rawValue }
    }

    var sectionGroups: [SectionGroup] {
        AssignedWorkout.Section.allCases.compactMap { section in
            guard let items = workout.sections[section], !items.isEmpty else { return nil }
            return SectionGroup(section: section, exercises: items)
        }
    }

    // MARK: Lifecycle

    func loadToday() async {
        today = .loading
        do {
            if let resumable = try await service.restoreIfNeeded() {
                session = resumable
                today = resumable.phase == .completed ? .finished(resumable) : .resume(resumable)
            } else {
                today = .ready(env.assignedWorkout)
            }
            await refreshSync()
        } catch {
            today = .failed(Self.message(for: error))
        }
    }

    func begin() async {
        do {
            let started = try await service.start(workout: env.assignedWorkout, epoch: 1)
            session = started
            selectedExerciseID = started.workout.allExercises.first?.id
            await afterWrite()
        } catch {
            transientError = Self.message(for: error)
        }
    }

    func resumeWorkout() async {
        do {
            try await service.resume()
            await syncSessionFromService()
            await afterWrite()
        } catch {
            transientError = Self.message(for: error)
        }
    }

    func pause() async { await run { try await self.service.pause() } }
    func exitKeepingProgress() async { await run { try await self.service.exit() } }

    func discard() async {
        cancelRest()
        await run { try await self.service.discard() }
    }

    func complete() async {
        cancelRest()
        do {
            let done = try await service.complete()
            session = done
            today = .finished(done)
            await afterWrite()
        } catch {
            transientError = Self.message(for: error)
        }
    }

    // MARK: Recording work

    /// Log the next set for an exercise. The set index is derived from what the domain has
    /// already recorded, so the domain's duplicate/ordering guarantees hold.
    func logSet(for exercise: AssignedExercise, value: SetEntry.Value, rpe: Double?) async {
        let index = setsRecorded(for: exercise)
        do {
            _ = try await service.recordSet(exerciseID: exercise.id, setIndex: index, value: value, rpe: rpe)
            await syncSessionFromService()
            startRest(seconds: exercise.restSeconds)
            await afterWrite()
        } catch {
            transientError = Self.message(for: error)
        }
    }

    func swap(_ exercise: AssignedExercise, to alternative: ExerciseSlug) async {
        await run { try await self.service.swapExercise(exercise.id, to: alternative) }
    }

    // MARK: Navigation between exercises

    func select(_ exercise: AssignedExercise) { selectedExerciseID = exercise.id }

    func advanceToNextExercise() {
        guard let current = selectedExercise,
              let idx = orderedExercises.firstIndex(where: { $0.id == current.id }),
              idx + 1 < orderedExercises.count else { return }
        selectedExerciseID = orderedExercises[idx + 1].id
    }

    func goToPreviousExercise() {
        guard let current = selectedExercise,
              let idx = orderedExercises.firstIndex(where: { $0.id == current.id }),
              idx > 0 else { return }
        selectedExerciseID = orderedExercises[idx - 1].id
    }

    // MARK: Rest timer (domain arithmetic is pure; this only drives ticks)

    var restIsPaused: Bool { restTimer?.isPaused ?? false }

    private func startRest(seconds: Int) {
        guard seconds > 0 else { return }
        restTimer = RestTimer(durationSeconds: seconds, startedAt: clock.now())
        restRemaining = seconds
        runTicker()
    }

    func extendRest(by seconds: Int) {
        guard var t = restTimer else { return }
        restTimer = t.extend(by: seconds)
        restRemaining = restTimer?.remainingSeconds(at: clock.now()) ?? 0
        runTicker()
    }

    func toggleRestPause() {
        guard var t = restTimer else { return }
        if t.isPaused { t.resume(at: clock.now()) } else { t.pause(at: clock.now()) }
        restTimer = t
        if !t.isPaused { runTicker() }
    }

    func skipRest() { cancelRest() }

    func restAccessibilityText() -> String {
        restTimer?.accessibilityDescription(at: clock.now()) ?? ""
    }

    private func runTicker() {
        restTicker?.cancel()
        restTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let timer = self.restTimer
                guard let timer, !timer.isPaused else { return }
                let remaining = timer.remainingSeconds(at: self.clock.now())
                self.restRemaining = remaining
                if remaining <= 0 {
                    self.restFinishedTick &+= 1
                    self.cancelRest()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func cancelRest() {
        restTicker?.cancel()
        restTicker = nil
        restTimer = nil
        restRemaining = 0
    }

    // MARK: Sync presentation

    /// Local write happened: reflect "saved on this phone" immediately, then try to drain
    /// the queue and report the honest result.
    private func afterWrite() async {
        let pending = await env.pendingOperationCount()
        if pending > 0 { sync = .savedLocally(pending: pending) }
        await refreshSync()
    }

    func refreshSync() async {
        let pendingBefore = await env.pendingOperationCount()
        guard pendingBefore > 0 else { sync = .synced; return }

        let status = (try? await env.syncEngine.syncOnce()) ?? .waitingForConnectivity(pending: pendingBefore)
        let remaining = await env.pendingOperationCount()
        switch status {
        case .idle:
            sync = remaining == 0 ? .synced : .savedLocally(pending: remaining)
        case let .syncing(r):
            sync = .syncing(remaining: r)
        case let .waitingForConnectivity(p):
            sync = .waitingForConnectivity(pending: max(p, remaining))
        case let .pausedAuthExpired(p):
            sync = .pausedAuthExpired(pending: p)
        case let .attentionNeeded(rejected):
            sync = .attentionNeeded(rejected: rejected)
        }
    }

    // MARK: Dev connectivity affordance (fixture only)

    var isOnline: Bool {
        get { env.connectivity.isOnline }
        set {
            env.connectivity.isOnline = newValue
            Task { await refreshSync() }
        }
    }

    // MARK: Private plumbing

    private func syncSessionFromService() async {
        session = await service.currentSession
    }

    /// Run a service mutation, mirror the resulting session, then refresh sync.
    private func run(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
            await syncSessionFromService()
            await afterWrite()
        } catch {
            transientError = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        guard let e = error as? WorkoutSessionError else {
            return "Something went wrong. Your recorded work is safe on this phone."
        }
        switch e {
        case .sessionReadOnly:
            return "This workout was continued on another device, so it's now read-only here. Your sets are saved."
        case let .swapNotApproved(slug):
            return "That alternative (\(slug.rawValue)) isn't one your coach approved."
        case .duplicateSet:
            return "That set is already recorded."
        case .unknownExercise:
            return "That exercise isn't part of this workout."
        case let .invalidTransition(_, action):
            return "Can't \(action) right now."
        }
    }
}
