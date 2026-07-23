import SwiftUI
import MazidiFoundations

@main
struct MazidiApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RoleShellView()
                .environment(appModel)
                .tint(MazidiColor.primary)
        }
    }
}

/// Root composition: which role shell is active. Coach and Client are separate shells with
/// separate navigation graphs — no shared screens, no cross-role route leakage.
@Observable
final class AppModel {
    enum ActiveRole {
        case signedOut
        case coach
        case client
    }

    var activeRole: ActiveRole = .signedOut
}

struct RoleShellView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        switch appModel.activeRole {
        case .signedOut:
            SignedOutView()
        case .coach:
            CoachShellView()
        case .client:
            ClientShellView()
        }
    }
}
