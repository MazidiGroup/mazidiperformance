import SwiftUI
import MazidiDomain
import MazidiFoundations

/// Navigation root for the Client workout slice. The account-scoped `ClientEnvironment`
/// is INJECTED by the session layer (ADR-0008) — this view never constructs storage —
/// and one long-lived `ClientWorkoutModel` is threaded to every screen.
struct ClientRootView: View {
    let environment: ClientEnvironment
    @Environment(SessionModel.self) private var session
    @State private var model: ClientWorkoutModel?
    @State private var path: [ClientRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    ClientHomeView(
                        model: model,
                        onViewWorkout: { path.append(.overview) },
                        // Navigate into the active workout only when resumption actually
                        // held (KNOWN_ISSUES M2) — a failed resume surfaces its error and
                        // stays on Today.
                        onResume: { Task { if await model.resumeWorkout() { path.append(.active) } } },
                        onViewSummary: { path.append(.complete) }
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Sign out") { Task { await session.signOut() } }
                                .accessibilityIdentifier("client_sign_out")
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationDestination(for: ClientRoute.self) { route in
                destination(route)
            }
        }
        .tint(MazidiColor.primary)
        .task {
            if model == nil { model = environment.makeWorkoutModel() }
            await model?.loadToday()
        }
    }

    @ViewBuilder private func destination(_ route: ClientRoute) -> some View {
        if let model {
            switch route {
            case .overview:
                WorkoutOverviewView(
                    model: model,
                    onBegin: { Task { await model.begin(); path.append(.active) } },
                    onOpenExercise: { path.append(.exercise($0.id)) }
                )
            case let .exercise(id):
                if let exercise = model.orderedExercises.first(where: { $0.id == id }) {
                    ExerciseDetailView(model: model, exercise: exercise)
                }
            case .active:
                ActiveWorkoutView(
                    model: model,
                    onExit: { path.removeAll(); Task { await model.loadToday() } },
                    onCompleted: { path = [.complete] }
                )
            case .complete:
                WorkoutCompleteView(model: model, onDone: {
                    path.removeAll()
                    Task { await model.loadToday() }
                })
            }
        }
    }
}

/// Value-based routes for the client navigation stack.
enum ClientRoute: Hashable {
    case overview
    case exercise(Identifier<AssignedExercise>)
    case active
    case complete
}
