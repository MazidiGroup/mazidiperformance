import Foundation
import GRDB
import MazidiDomain
import MazidiFoundations
import MazidiSync

/// Row shapes + domain↔row mappers (ADR-0007 §2). Only these record structs touch GRDB;
/// domain types are reconstructed through their explicit `init(restoring:)` entry points.
/// JSON blobs are limited to opaque snapshots (workout, set value, rest, payloads).

private let jsonEncoder = JSONEncoder()
private let jsonDecoder = JSONDecoder()

enum RecordMappingError: Error {
    case unknownEnumValue(table: String, column: String, value: String)
    case badUUID(table: String, column: String, value: String)
}

// MARK: - workout_session

struct WorkoutSessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workout_session"

    var id: String
    var epoch: Int
    var phase: String
    var startedAt: Date?
    var completedAt: Date?
    var currentExerciseId: String?
    var restJson: Data?
    var workoutJson: Data
    var assignmentId: String?

    enum CodingKeys: String, CodingKey {
        case id, epoch, phase
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case currentExerciseId = "current_exercise_id"
        case restJson = "rest_json"
        case workoutJson = "workout_json"
        case assignmentId = "assignment_id"
    }

    init(session: WorkoutSession) throws {
        id = session.id.rawValue.uuidString
        epoch = session.epoch
        phase = session.phase.rawValue
        startedAt = session.startedAt
        completedAt = session.completedAt
        currentExerciseId = session.currentExerciseID?.rawValue.uuidString
        restJson = try session.activeRest.map { try jsonEncoder.encode($0) }
        workoutJson = try jsonEncoder.encode(session.workout)
        assignmentId = session.assignmentID?.rawValue.uuidString
    }

    func toDomain(entries: [SetEntry], swaps: [Identifier<AssignedExercise>: ExerciseSlug]) throws -> WorkoutSession {
        guard let uuid = UUID(uuidString: id) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "id", value: id)
        }
        guard let phase = WorkoutSession.Phase(rawValue: phase) else {
            throw RecordMappingError.unknownEnumValue(table: Self.databaseTableName, column: "phase", value: phase)
        }
        return WorkoutSession(
            restoring: Identifier<WorkoutSession>(uuid),
            workout: try jsonDecoder.decode(AssignedWorkout.self, from: workoutJson),
            epoch: epoch,
            phase: phase,
            startedAt: startedAt,
            completedAt: completedAt,
            setEntries: entries,
            swaps: swaps,
            currentExerciseID: try currentExerciseId.map {
                guard let u = UUID(uuidString: $0) else {
                    throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "current_exercise_id", value: $0)
                }
                return Identifier<AssignedExercise>(u)
            },
            activeRest: try restJson.map { try jsonDecoder.decode(RestTimer.self, from: $0) },
            assignmentID: try assignmentId.map {
                guard let u = UUID(uuidString: $0) else {
                    throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "assignment_id", value: $0)
                }
                return Identifier<WorkoutAssignment>(u)
            }
        )
    }
}

// MARK: - workout_template / template_version / workout_assignment (ADR-0009)

struct WorkoutTemplateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workout_template"

    var id: String
    var draftJson: Data
    var publishedVersionCount: Int
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case draftJson = "draft_json"
        case publishedVersionCount = "published_version_count"
        case updatedAt = "updated_at"
    }

    init(template: WorkoutTemplate) throws {
        id = template.id.rawValue.uuidString
        draftJson = try jsonEncoder.encode(template.draft)
        publishedVersionCount = template.publishedVersionCount
        updatedAt = template.updatedAt
    }

    func toDomain() throws -> WorkoutTemplate {
        guard let uuid = UUID(uuidString: id) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "id", value: id)
        }
        return WorkoutTemplate(
            id: Identifier<WorkoutTemplate>(uuid),
            draft: try jsonDecoder.decode(WorkoutTemplateContent.self, from: draftJson),
            publishedVersionCount: publishedVersionCount,
            updatedAt: updatedAt
        )
    }
}

struct TemplateVersionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "template_version"

    var id: String
    var templateId: String
    var versionNumber: Int
    var contentJson: Data
    var publishedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case templateId = "template_id"
        case versionNumber = "version_number"
        case contentJson = "content_json"
        case publishedAt = "published_at"
    }

    init(version: WorkoutTemplateVersion) throws {
        id = version.id.rawValue.uuidString
        templateId = version.templateID.rawValue.uuidString
        versionNumber = version.versionNumber
        contentJson = try jsonEncoder.encode(version.content)
        publishedAt = version.publishedAt
    }

    func toDomain() throws -> WorkoutTemplateVersion {
        guard let uuid = UUID(uuidString: id), let templateUUID = UUID(uuidString: templateId) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "id/template_id", value: id)
        }
        return WorkoutTemplateVersion(
            id: Identifier<WorkoutTemplateVersion>(uuid),
            templateID: Identifier<WorkoutTemplate>(templateUUID),
            versionNumber: versionNumber,
            content: try jsonDecoder.decode(WorkoutTemplateContent.self, from: contentJson),
            publishedAt: publishedAt
        )
    }
}

struct WorkoutAssignmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workout_assignment"

    var id: String
    var templateId: String
    var versionId: String
    var versionNumber: Int
    var contentJson: Data
    var assigneeRef: String
    var assignedAt: Date
    var status: String
    var completedSessionId: String?
    var completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status
        case templateId = "template_id"
        case versionId = "version_id"
        case versionNumber = "version_number"
        case contentJson = "content_json"
        case assigneeRef = "assignee_ref"
        case assignedAt = "assigned_at"
        case completedSessionId = "completed_session_id"
        case completedAt = "completed_at"
    }

    init(assignment: WorkoutAssignment) throws {
        id = assignment.id.rawValue.uuidString
        templateId = assignment.templateID.rawValue.uuidString
        versionId = assignment.versionID.rawValue.uuidString
        versionNumber = assignment.versionNumber
        contentJson = try jsonEncoder.encode(assignment.content)
        assigneeRef = assignment.assigneeAccountRef
        assignedAt = assignment.assignedAt
        status = assignment.status.rawValue
        completedSessionId = assignment.completedSessionID?.rawValue.uuidString
        completedAt = assignment.completedAt
    }

    func toDomain() throws -> WorkoutAssignment {
        guard let uuid = UUID(uuidString: id),
              let templateUUID = UUID(uuidString: templateId),
              let versionUUID = UUID(uuidString: versionId) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "id/template_id/version_id", value: id)
        }
        guard let status = WorkoutAssignment.Status(rawValue: status) else {
            throw RecordMappingError.unknownEnumValue(table: Self.databaseTableName, column: "status", value: status)
        }
        return WorkoutAssignment(
            restoring: Identifier<WorkoutAssignment>(uuid),
            templateID: Identifier<WorkoutTemplate>(templateUUID),
            versionID: Identifier<WorkoutTemplateVersion>(versionUUID),
            versionNumber: versionNumber,
            content: try jsonDecoder.decode(WorkoutTemplateContent.self, from: contentJson),
            assigneeAccountRef: assigneeRef,
            assignedAt: assignedAt,
            status: status,
            completedSessionID: try completedSessionId.map {
                guard let u = UUID(uuidString: $0) else {
                    throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "completed_session_id", value: $0)
                }
                return Identifier<WorkoutSession>(u)
            },
            completedAt: completedAt
        )
    }
}

// MARK: - set_entry

struct SetEntryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "set_entry"

    var id: String
    var sessionId: String
    var exerciseId: String
    var performedSlug: String
    var setIndex: Int
    var valueJson: Data
    var rpe: Double?
    var recordedAt: Date
    var idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case exerciseId = "exercise_id"
        case performedSlug = "performed_slug"
        case setIndex = "set_index"
        case valueJson = "value_json"
        case rpe
        case recordedAt = "recorded_at"
        case idempotencyKey = "idempotency_key"
    }

    init(entry: SetEntry, sessionID: Identifier<WorkoutSession>) throws {
        id = entry.id.rawValue.uuidString
        sessionId = sessionID.rawValue.uuidString
        exerciseId = entry.exerciseID.rawValue.uuidString
        performedSlug = entry.performedSlug.rawValue
        setIndex = entry.setIndex
        valueJson = try jsonEncoder.encode(entry.value)
        rpe = entry.rpe
        recordedAt = entry.recordedAt
        idempotencyKey = entry.idempotencyKey.uuidString
    }

    func toDomain() throws -> SetEntry {
        guard let entryUUID = UUID(uuidString: id) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "id", value: id)
        }
        guard let exerciseUUID = UUID(uuidString: exerciseId) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "exercise_id", value: exerciseId)
        }
        guard let keyUUID = UUID(uuidString: idempotencyKey) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "idempotency_key", value: idempotencyKey)
        }
        return SetEntry(
            id: Identifier<SetEntry>(entryUUID),
            exerciseID: Identifier<AssignedExercise>(exerciseUUID),
            performedSlug: ExerciseSlug(performedSlug),
            setIndex: setIndex,
            value: try jsonDecoder.decode(SetEntry.Value.self, from: valueJson),
            rpe: rpe,
            recordedAt: recordedAt,
            idempotencyKey: keyUUID
        )
    }
}

// MARK: - exercise_swap

struct ExerciseSwapRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "exercise_swap"

    var sessionId: String
    var exerciseId: String
    var performedSlug: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case exerciseId = "exercise_id"
        case performedSlug = "performed_slug"
    }
}

// MARK: - outbox_operation

struct OutboxOperationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "outbox_operation"

    var id: String
    var kind: String
    var aggregateId: String
    var sequence: Int
    var idempotencyKey: String
    var payload: Data
    var enqueuedAt: Date
    var status: String
    var attemptCount: Int
    var lastError: String?
    var nextAttemptAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, sequence, payload, status
        case aggregateId = "aggregate_id"
        case idempotencyKey = "idempotency_key"
        case enqueuedAt = "enqueued_at"
        case attemptCount = "attempt_count"
        case lastError = "last_error"
        case nextAttemptAt = "next_attempt_at"
    }

    init(operation: SyncOperation) {
        id = operation.id.rawValue.uuidString
        kind = operation.kind.rawValue
        aggregateId = operation.aggregateID.uuidString
        sequence = operation.sequence
        idempotencyKey = operation.idempotencyKey.uuidString
        payload = operation.payload
        enqueuedAt = operation.enqueuedAt
        status = operation.status.rawValue
        attemptCount = operation.attemptCount
        lastError = operation.lastError
        nextAttemptAt = operation.nextAttemptAt
    }

    func toDomain() throws -> SyncOperation {
        guard let idUUID = UUID(uuidString: id) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "id", value: id)
        }
        guard let aggregateUUID = UUID(uuidString: aggregateId) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "aggregate_id", value: aggregateId)
        }
        guard let keyUUID = UUID(uuidString: idempotencyKey) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "idempotency_key", value: idempotencyKey)
        }
        guard let kind = SyncOperation.Kind(rawValue: kind) else {
            throw RecordMappingError.unknownEnumValue(table: Self.databaseTableName, column: "kind", value: kind)
        }
        guard let status = SyncOperation.Status(rawValue: status) else {
            throw RecordMappingError.unknownEnumValue(table: Self.databaseTableName, column: "status", value: status)
        }
        return SyncOperation(
            restoring: Identifier<SyncOperation>(idUUID),
            kind: kind,
            aggregateID: aggregateUUID,
            sequence: sequence,
            idempotencyKey: keyUUID,
            payload: payload,
            enqueuedAt: enqueuedAt,
            status: status,
            attemptCount: attemptCount,
            lastError: lastError,
            nextAttemptAt: nextAttemptAt
        )
    }
}

// MARK: - audit_event

struct AuditEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "audit_event"

    var id: String
    var kind: String
    var actorId: String
    var subject: String
    var occurredAt: Date
    var previousHash: String
    var payloadJson: Data

    enum CodingKeys: String, CodingKey {
        case id, kind, subject
        case actorId = "actor_id"
        case occurredAt = "occurred_at"
        case previousHash = "previous_hash"
        case payloadJson = "payload_json"
    }

    init(event: AuditEvent) throws {
        id = event.id.rawValue.uuidString
        kind = event.kind.rawValue
        actorId = event.actorID.uuidString
        subject = event.subjectDescription
        occurredAt = event.occurredAt
        previousHash = event.previousHash
        payloadJson = try jsonEncoder.encode(event.payload)
    }

    func toDomain() throws -> AuditEvent {
        guard let idUUID = UUID(uuidString: id) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "id", value: id)
        }
        guard let actorUUID = UUID(uuidString: actorId) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "actor_id", value: actorId)
        }
        guard let kind = AuditEvent.Kind(rawValue: kind) else {
            throw RecordMappingError.unknownEnumValue(table: Self.databaseTableName, column: "kind", value: kind)
        }
        return AuditEvent(
            id: Identifier<AuditEvent>(idUUID),
            kind: kind,
            actorID: actorUUID,
            subjectDescription: subject,
            occurredAt: occurredAt,
            previousHash: previousHash,
            payload: try jsonDecoder.decode([String: String].self, from: payloadJson)
        )
    }
}
