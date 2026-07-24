#if DEBUG
import Foundation
import MazidiAuth
import MazidiDomain
import MazidiFoundations
import MazidiPersistenceGRDB

/// FIXTURE — DEBUG-only local stand-in for the assignment delivery backend (ADR-0009).
///
/// Account databases are deliberately isolated (ADR-0008) and no backend exists
/// (R-01/R-02), so nothing can really "deliver" an assignment from a coach to a client.
/// For development and UI tests only, this relay copies a published assignment row
/// (a self-contained snapshot) into the dev assignee's account database, and pulls
/// lifecycle status back into the coach's database.
///
/// Honesty rules (enforced by callers/UI):
/// - Delivery via this relay NEVER upgrades the coach-side "Queued" state — delivery
///   confirmation only arrives with the real backend. Started/completed statuses pulled
///   back ARE real facts recorded by the client and may be shown (labelled as dev relay).
/// - Compiled out of Release entirely; production behaviour is the durable outbox queue.
enum DevelopmentAssignmentRelay {
    /// Copy the assignment into the assignee's account database (dev accounts only).
    static func deliver(_ assignment: WorkoutAssignment) async {
        guard DevelopmentAuthProvider.identities.keys.contains(assignment.assigneeAccountRef) else {
            return // never relays to non-fixture identities
        }
        do {
            let base = try CoachEnvironment.storeBase()
            let assigneeDir = AccountDatabasePath.directory(
                base: base, accountID: AccountID(assignment.assigneeAccountRef)
            )
            let store = try GRDBStore.open(directory: assigneeDir)
            try await store.saveAssignmentAtomically(assignment, enqueueing: [])
            try store.close()
        } catch {
            AppLog(category: "dev-relay").error("Dev delivery failed: \(error)")
        }
    }

    /// Pull lifecycle status updates for the coach's assignments back from the
    /// assignees' databases. Returns the refreshed assignments (only rows whose status
    /// advanced are rewritten coach-side by the caller).
    static func collectStatuses(for assignments: [WorkoutAssignment]) async -> [WorkoutAssignment] {
        var updated: [WorkoutAssignment] = []
        for assignment in assignments where assignment.status == .queued || assignment.status == .started {
            guard DevelopmentAuthProvider.identities.keys.contains(assignment.assigneeAccountRef) else { continue }
            guard let base = try? CoachEnvironment.storeBase() else { continue }
            let assigneeDir = AccountDatabasePath.directory(
                base: base, accountID: AccountID(assignment.assigneeAccountRef)
            )
            guard let store = try? GRDBStore.open(directory: assigneeDir) else { continue }
            if let theirs = try? await store.assignment(id: assignment.id),
               theirs.status != assignment.status {
                updated.append(theirs)
            }
            try? store.close()
        }
        return updated
    }
}
#endif
