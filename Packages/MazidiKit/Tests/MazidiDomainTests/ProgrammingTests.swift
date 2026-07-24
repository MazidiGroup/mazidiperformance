import Foundation
import Testing
@testable import MazidiDomain
import MazidiFoundations

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

private func squat(order: Int = 0) -> PrescribedExercise {
    PrescribedExercise(
        slug: "barbell-squat", order: order,
        prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80),
        coachNotes: "Brace hard", approvedAlternatives: ["kettlebell-sumo-deadlift"]
    )
}

private func row(order: Int = 1) -> PrescribedExercise {
    PrescribedExercise(
        slug: "barbell-bent-over-row", order: order,
        prescription: .repsOnly(sets: 2, reps: 8...10), tempo: "3-1-1-0"
    )
}

@Suite struct ProgrammingDomainTests {
    @Test func draftCreationAndExerciseOrdering() {
        var template = WorkoutTemplate(
            draft: WorkoutTemplateContent(title: "Lower A", exercises: [row(order: 5), squat(order: 2)]),
            updatedAt: t0
        )
        template.draft.normalizeOrder()
        // Sorted by order, then reassigned contiguously.
        #expect(template.draft.exercises.map(\.slug) == ["barbell-squat", "barbell-bent-over-row"])
        #expect(template.draft.exercises.map(\.order) == [0, 1])

        // Reorder: move row first, orders reassert deterministically.
        template.draft.exercises[1].order = -1
        template.draft.normalizeOrder()
        #expect(template.draft.exercises.map(\.slug) == ["barbell-bent-over-row", "barbell-squat"])
        #expect(template.draft.exercises.map(\.order) == [0, 1])
    }

    @Test func publicationValidationCatchesEveryRule() {
        let empty = WorkoutTemplateContent(title: "  ", exercises: [])
        #expect(empty.validateForPublication().contains(.emptyTitle))
        #expect(empty.validateForPublication().contains(.noExercises))

        var unsupported = squat()
        unsupported.prescription = .unsupported(description: "wave loading 5/3/1+")
        let content = WorkoutTemplateContent(title: "X", exercises: [unsupported])
        #expect(content.validateForPublication() == [.unsupportedPrescription("barbell-squat")])

        var zeroSets = squat()
        zeroSets.prescription = .repsOnly(sets: 0, reps: 1...5)
        let zero = WorkoutTemplateContent(title: "X", exercises: [zeroSets])
        #expect(zero.validateForPublication() == [.invalidSetCount("barbell-squat")])
    }

    @Test func unsupportedPrescriptionIsRepresentedSafelyNotCoerced() {
        let target = SetPrescription.unsupported(description: "contrast pairs")
        #expect(!target.isExecutable)
        #expect(target.executionPrescription == nil)
        #expect(target.setCount == 0)
        // Draft may hold it; publication must refuse it.
        var template = WorkoutTemplate(
            draft: WorkoutTemplateContent(title: "Adv", exercises: [
                PrescribedExercise(slug: "barbell-squat", order: 0, prescription: target),
            ]),
            updatedAt: t0
        )
        #expect(throws: WorkoutTemplate.PublicationError.self) {
            _ = try template.publish(at: t0)
        }
    }

    @Test func publishingCreatesImmutableMonotonicVersions() throws {
        var template = WorkoutTemplate(
            draft: WorkoutTemplateContent(title: "Lower A", exercises: [squat(), row()]),
            updatedAt: t0
        )
        let v1 = try template.publish(at: t0)
        #expect(v1.versionNumber == 1)
        #expect(template.publishedVersionCount == 1)

        // Editing after publication mutates the draft only; the published value is frozen.
        template.draft.title = "Lower A — heavier"
        template.draft.exercises[0].prescription = .repsAndLoad(sets: 5, reps: 3...5, loadKg: 100)
        #expect(v1.content.title == "Lower A")
        guard case let .repsAndLoad(sets, _, load) = v1.content.exercises[0].prescription else {
            Issue.record("v1 content changed shape"); return
        }
        #expect(sets == 3 && load == 80)

        let v2 = try template.publish(at: t0.addingTimeInterval(60))
        #expect(v2.versionNumber == 2)
        #expect(v2.content.title == "Lower A — heavier")
        #expect(v1.content.title == "Lower A") // still frozen
    }

    @Test func assignmentFreezesVersionAndSurvivesLaterEdits() throws {
        var template = WorkoutTemplate(
            draft: WorkoutTemplateContent(title: "Lower A", exercises: [squat(), row()]),
            updatedAt: t0
        )
        let v1 = try template.publish(at: t0)
        let assignment = WorkoutAssignment(version: v1, assigneeAccountRef: "dev-client-001", assignedAt: t0)
        #expect(assignment.versionID == v1.id)
        #expect(assignment.versionNumber == 1)
        #expect(assignment.status == .queued)

        // Coach edits + republishes; the assignment's snapshot is untouched.
        template.draft.title = "Changed"
        _ = try template.publish(at: t0.addingTimeInterval(60))
        #expect(assignment.content.title == "Lower A")
    }

    @Test func assignmentLifecycleAndDuplicateCompletionPrevention() throws {
        var template = WorkoutTemplate(
            draft: WorkoutTemplateContent(title: "Lower A", exercises: [squat()]),
            updatedAt: t0
        )
        let version = try template.publish(at: t0)
        var assignment = WorkoutAssignment(version: version, assigneeAccountRef: "dev-client-001", assignedAt: t0)

        try assignment.markStarted()
        #expect(assignment.status == .started)
        try assignment.markStarted() // starting again is tolerated (same session resumes)

        let sessionID = Identifier<WorkoutSession>()
        try assignment.markCompleted(sessionID: sessionID, at: t0.addingTimeInterval(1800))
        #expect(assignment.status == .completed)
        #expect(assignment.completedSessionID == sessionID)

        // Duplicate completion (relaunch replay) is refused.
        #expect(throws: WorkoutAssignment.TransitionError.alreadyCompleted) {
            try assignment.markCompleted(sessionID: Identifier<WorkoutSession>(), at: t0.addingTimeInterval(3600))
        }
        // A completed assignment cannot be cancelled either.
        #expect(throws: WorkoutAssignment.TransitionError.self) { try assignment.markCancelled() }
    }

    @Test func cancellationAllowedFromQueuedAndStartedOnly() throws {
        var template = WorkoutTemplate(
            draft: WorkoutTemplateContent(title: "L", exercises: [squat()]), updatedAt: t0
        )
        let version = try template.publish(at: t0)
        var queued = WorkoutAssignment(version: version, assigneeAccountRef: "c", assignedAt: t0)
        try queued.markCancelled()
        #expect(queued.status == .cancelled)
        #expect(throws: WorkoutAssignment.TransitionError.self) { try queued.markStarted() }
    }

    @Test func assignmentToSessionConversionSeedsExecutionFaithfully() throws {
        var template = WorkoutTemplate(
            draft: WorkoutTemplateContent(title: "Lower A", exercises: [squat(), row()]),
            updatedAt: t0
        )
        let version = try template.publish(at: t0)
        let assignment = WorkoutAssignment(version: version, assigneeAccountRef: "dev-client-001", assignedAt: t0)

        let workout = try assignment.assignedWorkout()
        #expect(workout.title == "Lower A")
        #expect(workout.programmeVersion == 1)
        let exercises = workout.allExercises
        #expect(exercises.count == 2)
        #expect(exercises[0].slug == "barbell-squat")
        #expect(exercises[0].prescription == .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80))
        #expect(exercises[0].coachCue == "Brace hard")
        #expect(exercises[0].approvedAlternatives == ["kettlebell-sumo-deadlift"])
        #expect(exercises[1].coachCue == "Tempo 3-1-1-0") // tempo rides along as text

        // The session engine consumes it unchanged, carrying the assignment link.
        var session = WorkoutSession(workout: workout, epoch: 1, assignmentID: assignment.id)
        try session.start(at: t0)
        #expect(session.assignmentID == assignment.id)
        _ = try session.recordSet(
            exerciseID: exercises[0].id, setIndex: 0,
            value: .repsAndLoad(reps: 6, loadKg: 80), at: t0
        )
        #expect(session.setEntries.count == 1)
    }
}
