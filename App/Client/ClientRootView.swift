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
    @State private var consentModel: HealthDataConsentModel?
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
                        onViewSummary: { path.append(.complete) },
                        onReviewConsent: { showConsent() }
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Privacy") { path.append(.privacy) }
                                .accessibilityIdentifier(A11yID.privacyOpenButton)
                        }
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
            if consentModel == nil { consentModel = HealthDataConsentModel(environment: environment) }
            await model?.loadToday()
        }
        // A health-collection attempt refused by the consent gate (ADR-0013) routes here,
        // wherever in the stack it happened. The attempted entry is held by the model, not
        // dropped, so consenting records it and declining leaves it visible to discard.
        .onChange(of: model?.consentRequired) { _, purpose in
            if purpose != nil, path.last != .healthConsent { showConsent() }
        }
    }

    private func showConsent() {
        if path.last != .healthConsent { path.append(.healthConsent) }
    }

    @ViewBuilder private func destination(_ route: ClientRoute) -> some View {
        if let model {
            switch route {
            case .overview:
                WorkoutOverviewView(
                    model: model,
                    // Starting a session records health data, so it is gated: on refusal the
                    // consent screen opens instead of the workout (KNOWN_ISSUES M2 pattern).
                    onBegin: {
                        Task {
                            if await model.begin() { path.append(.active) } else { showConsent() }
                        }
                    },
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
                    onCompleted: { path = [.complete] },
                    onReviewConsent: { showConsent() }
                )
            case .complete:
                WorkoutCompleteView(model: model, onDone: {
                    path.removeAll()
                    Task { await model.loadToday() }
                })
            case .healthConsent:
                if let consentModel {
                    HealthDataConsentView(model: consentModel) {
                        if path.last == .healthConsent { path.removeLast() }
                        Task { await model.consentDidChange() }
                    }
                }
            case .privacy:
                if let consentModel {
                    HealthDataPrivacyView(model: consentModel, onGrant: { showConsent() })
                        .onDisappear { Task { await model.consentDidChange() } }
                }
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
    /// Health-data consent (ADR-0013) — reached before any collection, and from Privacy.
    case healthConsent
    /// Privacy / withdrawal surface (Art. 7(3): as easy to withdraw as to give).
    case privacy
}
