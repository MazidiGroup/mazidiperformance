import Foundation
import Observation
import MazidiContent
import MazidiDomain
import MazidiFoundations
import MazidiSync

/// View-model for the Coach programming flow (ADR-0009). Thin adapter over the
/// programming repository: drafting/publishing/assignment rules live in the domain;
/// every mutating write commits atomically with its outbox operation.
@MainActor
@Observable
final class CoachProgrammingModel {
    private(set) var templates: [WorkoutTemplate] = []
    private(set) var versionsByTemplate: [Identifier<WorkoutTemplate>: [WorkoutTemplateVersion]] = [:]
    private(set) var assignments: [WorkoutAssignment] = []
    private(set) var relationships: [Relationship] = []
    var transientError: String?

    private let env: CoachEnvironment
    private var store: CoachStore { env.store }

    init(environment: CoachEnvironment) {
        self.env = environment
    }

    // MARK: - Catalogue access for the editor/picker (ADR-0011)

    /// Client-content copy (display names, aliases, draft coaching content) by slug.
    var content: any ExerciseContentProviding { env.content }
    /// Catalogue query store: search/filter/vocabularies over canonical exercises.
    var catalogueStore: ExerciseCatalogueStore { env.catalogueStore }
    /// Media resolver for picker/preview posters (bundled tier + honest fallback).
    var media: any MediaResolving { env.media }

    // MARK: - Loading

    func load() async {
        do {
            templates = try await store.programming.allTemplates()
            assignments = try await store.programming.allAssignments()
            relationships = try await store.relationships.allRelationships()
            for template in templates {
                versionsByTemplate[template.id] = try await store.programming.versions(templateID: template.id)
            }
            #if DEBUG
            // Dev relay (backend stand-in): pull real lifecycle facts recorded by dev
            // clients. Never upgrades delivery confirmation (ADR-0009 honesty rule).
            let advanced = await DevelopmentAssignmentRelay.collectStatuses(for: assignments)
            for refreshed in advanced {
                try await store.programming.saveAssignmentAtomically(refreshed, enqueueing: [])
            }
            if !advanced.isEmpty {
                assignments = try await store.programming.allAssignments()
            }
            #endif
        } catch {
            transientError = "Couldn't load your workouts."
        }
    }

    // MARK: - Drafting

    @discardableResult
    func createDraft(title: String) async -> WorkoutTemplate? {
        let template = WorkoutTemplate(
            draft: WorkoutTemplateContent(title: title),
            updatedAt: env.clock.now()
        )
        do {
            try await persistDraft(template, isNew: true)
            return template
        } catch {
            transientError = "Couldn't save the draft."
            return nil
        }
    }

    func updateDraft(_ template: WorkoutTemplate, mutate: (inout WorkoutTemplateContent) -> Void) async {
        var updated = template
        mutate(&updated.draft)
        updated.draft.normalizeOrder()
        updated.updatedAt = env.clock.now()
        do {
            try await persistDraft(updated, isNew: false)
        } catch {
            transientError = "Couldn't save the draft."
        }
    }

    private func persistDraft(_ template: WorkoutTemplate, isNew: Bool) async throws {
        let aggregate = template.id.rawValue
        let op = SyncOperation(
            kind: .templateDraftSaved,
            aggregateID: aggregate,
            sequence: try await store.operations.nextSequence(forAggregate: aggregate),
            payload: try JSONEncoder().encode(template),
            enqueuedAt: env.clock.now()
        )
        try await store.programming.saveTemplateAtomically(template, enqueueing: [op])
        if isNew {
            try? await appendAudit(.workoutDraftCreated, subject: "template:\(template.id)")
        }
        await refreshTemplates()
    }

    // MARK: - Publishing

    @discardableResult
    func publish(_ template: WorkoutTemplate) async -> WorkoutTemplateVersion? {
        var mutable = template
        do {
            let version = try mutable.publish(at: env.clock.now())
            let aggregate = template.id.rawValue
            let op = SyncOperation(
                kind: .templatePublished,
                aggregateID: aggregate,
                sequence: try await store.operations.nextSequence(forAggregate: aggregate),
                payload: try JSONEncoder().encode(version),
                enqueuedAt: env.clock.now()
            )
            try await store.programming.publishAtomically(
                template: mutable, version: version, enqueueing: [op]
            )
            try? await appendAudit(.programmePublished, subject: "templateVersion:\(version.id)")
            await refreshTemplates()
            versionsByTemplate[template.id] = try await store.programming.versions(templateID: template.id)
            return version
        } catch let error as WorkoutTemplate.PublicationError {
            transientError = Self.publicationMessage(error)
            return nil
        } catch {
            transientError = "Couldn't publish the workout."
            return nil
        }
    }

    // MARK: - Assigning

    @discardableResult
    func assign(version: WorkoutTemplateVersion, toClientRef clientRef: String) async -> WorkoutAssignment? {
        let assignment = WorkoutAssignment(
            version: version,
            assigneeAccountRef: clientRef,
            assignedAt: env.clock.now()
        )
        do {
            let aggregate = assignment.id.rawValue
            let op = SyncOperation(
                kind: .assignmentCreated,
                aggregateID: aggregate,
                sequence: try await store.operations.nextSequence(forAggregate: aggregate),
                payload: try JSONEncoder().encode(assignment),
                enqueuedAt: env.clock.now()
            )
            try await store.programming.saveAssignmentAtomically(assignment, enqueueing: [op])
            try? await appendAudit(.workoutAssigned, subject: "assignment:\(assignment.id)")
            #if DEBUG
            await DevelopmentAssignmentRelay.deliver(assignment)
            #endif
            assignments = try await store.programming.allAssignments()
            return assignment
        } catch {
            transientError = "Couldn't assign the workout."
            return nil
        }
    }

    // MARK: - Coach–Client relationships (ADR-0012 §6)

    /// Create a relationship to a client. Coach-only by construction: this API lives on the
    /// Coach shell's model; the client shell has no relationship-creation path. The coach is
    /// always the current account. Authorization is advisory locally — real relationship
    /// authorization is a backend responsibility (R-01/R-02).
    @discardableResult
    func createRelationship(clientRef: String) async -> Relationship? {
        let relationship = Relationship(
            coachAccountRef: env.accountID.rawValue,
            clientAccountRef: clientRef,
            status: .pendingLocalUpload,
            createdAt: env.clock.now()
        )
        return await persistRelationship(relationship) ? relationship : nil
    }

    /// Activate a relationship (invitation accepted / server-confirmed in a real backend).
    @discardableResult
    func activateRelationship(_ relationship: Relationship) async -> Bool {
        var mutable = relationship
        do { try mutable.activate(at: env.clock.now()) } catch { transientError = "That relationship can't be activated."; return false }
        return await persistRelationship(mutable)
    }

    /// End an active relationship (blocks new access; existing history retained).
    @discardableResult
    func endRelationship(_ relationship: Relationship) async -> Bool {
        var mutable = relationship
        do { try mutable.end(at: env.clock.now()) } catch { transientError = "That relationship can't be ended."; return false }
        return await persistRelationship(mutable)
    }

    private func persistRelationship(_ relationship: Relationship) async -> Bool {
        let aggregate = relationship.id.rawValue
        do {
            let op = SyncOperation(
                kind: .relationshipUpdated,
                aggregateID: aggregate,
                sequence: try await store.operations.nextSequence(forAggregate: aggregate),
                payload: try JSONEncoder().encode(relationship),
                enqueuedAt: env.clock.now()
            )
            try await store.relationships.saveRelationshipAtomically(relationship, enqueueing: [op])
            relationships = try await store.relationships.allRelationships()
            await env.drainOutbox()
            return true
        } catch {
            transientError = "Couldn't save the relationship."
            return false
        }
    }

    // MARK: - Presentation helpers

    func latestVersion(of template: WorkoutTemplate) -> WorkoutTemplateVersion? {
        versionsByTemplate[template.id]?.last
    }

    func assignments(for template: WorkoutTemplate) -> [WorkoutAssignment] {
        assignments.filter { $0.templateID == template.id }
    }

    private func refreshTemplates() async {
        templates = (try? await store.programming.allTemplates()) ?? templates
    }

    private func appendAudit(_ kind: AuditEvent.Kind, subject: String) async throws {
        let previous = try await store.audit.latestHash()
        try await store.audit.append(AuditEvent(
            kind: kind,
            actorID: env.accountID.stableActorUUID,
            subjectDescription: subject,
            occurredAt: env.clock.now(),
            previousHash: previous
        ))
    }

    private static func publicationMessage(_ error: WorkoutTemplate.PublicationError) -> String {
        guard case let .validationFailed(issues) = error, let first = issues.first else {
            return "The workout isn't ready to publish."
        }
        switch first {
        case .emptyTitle: return "Give the workout a title before publishing."
        case .noExercises: return "Add at least one exercise before publishing."
        case .unsupportedPrescription: return "One exercise has a prescription the app can't run yet."
        case .invalidSetCount: return "Every exercise needs at least one set."
        }
    }
}
