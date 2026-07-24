import SwiftUI

/// Placeholder sign-in surface — authentication lands with its backend contract (R-01).
/// Role selection here is a development affordance behind DEBUG, not a product flow.
struct SignedOutView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Mazidi Performance")
                .font(.largeTitle.bold())
                .foregroundStyle(MazidiColor.text)
            Text("Sign-in arrives with the backend contract.")
                .foregroundStyle(MazidiColor.textSecondary)
            #if DEBUG
            Button("Continue as Client (dev)") { appModel.activeRole = .client }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("dev_continue_client")
            Button("Continue as Coach (dev)") { appModel.activeRole = .coach }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("dev_continue_coach")
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MazidiColor.background)
    }
}

/// Client shell — slice 1 Today → Workout journey (panels 3a–3e, 4a/4b, 5a/5b, 7b/7d/7g).
/// The real navigation graph and dependency wiring live in `ClientRootView`.
struct ClientShellView: View {
    var body: some View {
        ClientRootView()
    }
}

/// Coach shell — phases 3–4. Kept separate from the client graph by construction.
struct CoachShellView: View {
    var body: some View {
        NavigationStack {
            Text("Coach dashboard — phase 4")
                .foregroundStyle(MazidiColor.textSecondary)
                .navigationTitle("Today")
        }
    }
}
