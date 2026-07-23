import Foundation
import Testing
@testable import MazidiDomain
import MazidiFoundations

private func makeWorkout(
    alternatives: [ExerciseSlug] = ["barbell-bent-over-row"]
) -> (AssignedWorkout, AssignedExercise, AssignedExercise) {
    let squat = AssignedExercise(
        slug: "barbell-squat",
        prescription: .repsAndLoad(sets: 2, reps: 5...8, loadKg: 80),
        coachCue: "Brace before you descend",
        approvedAlternatives: alternatives,
        restSeconds: 120
    )
    let plank = AssignedExercise(slug: "plank", prescription: .timed(sets: 1, seconds: 60))
    let workout = AssignedWorkout(
        title: "Lower A",
        programmeVersion: 3,
        sections: [.main: [squat], .coolDown: [plank]]
    )
    return (workout, squat, plank)
}

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

@Suite struct WorkoutSessionLifecycleTests {
    @Test func startPauseResumeComplete() throws {
        let (workout, squat, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        #expect(s.phase == .notStarted)
        try s.start(at: t0)
        #expect(s.phase == .active)
        #expect(s.startedAt == t0)
        _ = try s.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80), at: t0)
        try s.pause()
        #expect(s.phase == .paused)
        try s.resume()
        try s.complete(at: t0.addingTimeInterval(1800))
        #expect(s.phase == .completed)
        #expect(s.setEntries.count == 1)
    }

    @Test func cannotStartTwice() throws {
        let (workout, _, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        try s.start(at: t0)
        #expect(throws: WorkoutSessionError.invalidTransition(from: .active, action: "start")) {
            try s.start(at: t0)
        }
    }

    @Test func exitKeepsProgressAndAllowsResume() throws {
        let (workout, squat, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        try s.start(at: t0)
        _ = try s.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 8, loadKg: 80), at: t0)
        try s.exitKeepingProgress()
        #expect(s.phase == .paused)
        #expect(s.setEntries.count == 1) // "nothing lost" (5a)
        try s.resume()
        #expect(s.phase == .active)
    }

    @Test func abandonBlocksFurtherWritesButKeepsHistory() throws {
        let (workout, squat, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        try s.start(at: t0)
        _ = try s.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80), at: t0)
        try s.abandon()
        #expect(s.phase == .abandoned)
        #expect(s.setEntries.count == 1)
        #expect(throws: (any Error).self) {
            _ = try s.recordSet(exerciseID: squat.id, setIndex: 1, value: .repsAndLoad(reps: 6, loadKg: 80), at: t0)
        }
    }

    @Test func completionRequiresStartedSession() {
        let (workout, _, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        #expect(throws: WorkoutSessionError.invalidTransition(from: .notStarted, action: "complete")) {
            try s.complete(at: t0)
        }
    }
}

@Suite struct WorkoutSessionRecordingTests {
    @Test func duplicateSetIndexRejected() throws {
        let (workout, squat, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        try s.start(at: t0)
        _ = try s.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80), at: t0)
        #expect(throws: WorkoutSessionError.duplicateSet(exercise: squat.id, setIndex: 0)) {
            _ = try s.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 7, loadKg: 80), at: t0)
        }
    }

    @Test func unknownExerciseRejected() throws {
        let (workout, _, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        try s.start(at: t0)
        let ghost = Identifier<AssignedExercise>()
        #expect(throws: WorkoutSessionError.unknownExercise(ghost)) {
            _ = try s.recordSet(exerciseID: ghost, setIndex: 0, value: .reps(10), at: t0)
        }
    }

    @Test func prescriptionCompletionTracking() throws {
        let (workout, squat, plank) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        try s.start(at: t0)
        #expect(!s.isEveryPrescribedSetRecorded)
        _ = try s.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80), at: t0)
        _ = try s.recordSet(exerciseID: squat.id, setIndex: 1, value: .repsAndLoad(reps: 6, loadKg: 82.5), at: t0)
        _ = try s.recordSet(exerciseID: plank.id, setIndex: 0, value: .time(seconds: 60), at: t0)
        #expect(s.isEveryPrescribedSetRecorded)
        #expect(s.completedSetCount(for: squat.id) == 2)
    }
}

@Suite struct WorkoutSessionSwapTests {
    @Test func swapToApprovedAlternative() throws {
        let (workout, squat, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        try s.start(at: t0)
        try s.swapExercise(squat.id, to: "barbell-bent-over-row")
        let entry = try s.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 8, loadKg: 60), at: t0)
        #expect(entry.performedSlug == "barbell-bent-over-row")
    }

    @Test func unapprovedSwapRejected() throws {
        let (workout, squat, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        try s.start(at: t0)
        #expect(throws: WorkoutSessionError.swapNotApproved("kettlebell-sumo-deadlift")) {
            try s.swapExercise(squat.id, to: "kettlebell-sumo-deadlift")
        }
    }

    @Test func earlierSetsKeepOriginalSlugAfterSwap() throws {
        let (workout, squat, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        try s.start(at: t0)
        let before = try s.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80), at: t0)
        try s.swapExercise(squat.id, to: "barbell-bent-over-row")
        let after = try s.recordSet(exerciseID: squat.id, setIndex: 1, value: .repsAndLoad(reps: 8, loadKg: 60), at: t0)
        #expect(before.performedSlug == "barbell-squat")
        #expect(after.performedSlug == "barbell-bent-over-row")
    }
}

@Suite struct OneDeviceRuleTests {
    @Test func newerEpochSupersedesLiveSession() throws {
        let (workout, squat, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        try s.start(at: t0)
        _ = try s.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80), at: t0)
        s.markSuperseded(byEpoch: 2)
        #expect(s.phase == .supersededReadOnly)
        // Data preserved, writes blocked with a distinct, honest error (5f).
        #expect(s.setEntries.count == 1)
        #expect(throws: WorkoutSessionError.sessionReadOnly) {
            _ = try s.recordSet(exerciseID: squat.id, setIndex: 1, value: .repsAndLoad(reps: 6, loadKg: 80), at: t0)
        }
    }

    @Test func olderOrEqualEpochNeverSupersedes() throws {
        let (workout, _, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 3)
        try s.start(at: t0)
        s.markSuperseded(byEpoch: 3)
        s.markSuperseded(byEpoch: 2)
        #expect(s.phase == .active)
    }

    @Test func completedHistoryIsNeverRetroactivelySuperseded() throws {
        let (workout, _, _) = makeWorkout()
        var s = WorkoutSession(workout: workout, epoch: 1)
        try s.start(at: t0)
        try s.complete(at: t0)
        s.markSuperseded(byEpoch: 99)
        #expect(s.phase == .completed)
    }
}

@Suite struct RestTimerTests {
    @Test func countsDownAndFinishes() {
        let timer = RestTimer(durationSeconds: 90, startedAt: t0)
        #expect(timer.remainingSeconds(at: t0) == 90)
        #expect(timer.remainingSeconds(at: t0.addingTimeInterval(30)) == 60)
        #expect(timer.isFinished(at: t0.addingTimeInterval(90)))
        #expect(timer.remainingSeconds(at: t0.addingTimeInterval(500)) == 0) // clamps, no negatives
    }

    @Test func pauseFreezesRemaining() {
        var timer = RestTimer(durationSeconds: 60, startedAt: t0)
        timer.pause(at: t0.addingTimeInterval(20))
        #expect(timer.remainingSeconds(at: t0.addingTimeInterval(50)) == 40)
        timer.resume(at: t0.addingTimeInterval(50))
        #expect(timer.remainingSeconds(at: t0.addingTimeInterval(60)) == 30)
    }

    @Test func accessibilityDescriptionIsNumeric() {
        let timer = RestTimer(durationSeconds: 45, startedAt: t0)
        #expect(timer.accessibilityDescription(at: t0) == "Rest: 45 seconds remaining")
    }
}
