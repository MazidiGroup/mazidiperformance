import SwiftUI
import MazidiAuth

@main
struct MazidiApp: App {
    @State private var session = SessionModel()

    var body: some Scene {
        WindowGroup {
            SessionRootView()
                .environment(session)
                .tint(MazidiColor.primary)
                .task { await session.start() }
        }
    }
}

/// Root composition: a pure function of the session route (ADR-0008). Coach and Client
/// remain separate shells with separate navigation graphs; role comes only from the
/// session's claims — never a preference read here, never a launch argument.
///
/// In `LOCAL_IDENTITY` builds (Debug + Staging/TestFlight) those claims can be issued by
/// the local test profile the tester chose (ADR-0014): the choice is made *before* a
/// session exists, is minted into a role-scoped account, and reaches this view only as
/// ordinary claims. Release is unchanged — no role is obtainable there at all.
struct SessionRootView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        switch session.route {
        case let .signedOut(pendingRemoteRevocation):
            SignInView(pendingRemoteRevocation: pendingRemoteRevocation)
        case .authenticating:
            ProgressSurface(
                title: "Signing in…",
                cancelLabel: "Cancel",
                cancelID: "auth_cancel_button",
                onCancel: { Task { await session.cancelAuthentication() } }
            )
        case let .authenticationFailed(message):
            AuthMessageSurface(
                badge: ("Sign-in failed", "exclamationmark.triangle", .danger),
                message: message,
                actionLabel: "Try again",
                actionID: "auth_retry_button",
                action: { Task { await session.acknowledgeFailure() } }
            )
        case .clientShell:
            if let environment = session.clientEnvironment {
                #if LOCAL_IDENTITY
                // Test builds label the local profile honestly and host the role switch
                // (ADR-0014). Not compiled into Release.
                LocalProfileShell {
                    ClientRootView(environment: environment)
                        .id(ObjectIdentifier(environment)) // fresh navigation per account
                }
                #else
                ClientRootView(environment: environment)
                    .id(ObjectIdentifier(environment)) // fresh navigation per account
                #endif
            } else {
                ProgressSurface(title: "Opening your data…")
            }
        case let .coachShell(accountLabel):
            #if LOCAL_IDENTITY
            LocalProfileShell { CoachShellView(accountLabel: accountLabel) }
            #else
            CoachShellView(accountLabel: accountLabel)
            #endif
        case let .roleError(reason):
            AuthMessageSurface(
                badge: ("Account issue", "person.crop.circle.badge.questionmark", .warning),
                message: reason + " Contact your coach or support, or sign out.",
                actionLabel: "Sign out",
                actionID: "role_error_sign_out",
                action: { Task { await session.signOut() } }
            )
        case .storageFailure:
            AuthMessageSurface(
                badge: ("Storage unavailable", "externaldrive.badge.xmark", .danger),
                message: "You're signed in, but your workout storage couldn't be opened on this device, so your data isn't available right now. Nothing was deleted.",
                actionLabel: "Sign out",
                actionID: "storage_failure_sign_out",
                action: { Task { await session.signOut() } }
            )
        case .signingOut:
            ProgressSurface(title: "Signing out…")
        case .locked:
            AuthMessageSurface(
                badge: ("Locked", "lock.fill", .info),
                message: "Mazidi Performance is locked.",
                actionLabel: "Unlock",
                actionID: "unlock_button",
                action: { Task { await session.unlock() } }
            )
        case .revoked:
            AuthMessageSurface(
                badge: ("Signed out remotely", "lock.slash", .warning),
                message: "This session was ended (for example from another device), so this device was signed out. Sign in again to continue.",
                actionLabel: "OK",
                actionID: "revoked_acknowledge_button",
                action: { Task { await session.acknowledgeFailure() } }
            )
        }
    }
}

// MARK: - Shared auth surfaces

private struct ProgressSurface: View {
    let title: String
    var cancelLabel: String?
    var cancelID: String?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: MazidiMetric.stackSpacing) {
            ProgressView()
            Text(title)
                .font(MazidiFont.callout)
                .foregroundStyle(MazidiColor.textSecondary)
            if let cancelLabel, let onCancel {
                Button(cancelLabel, action: onCancel)
                    .buttonStyle(.mazidiSecondary)
                    .fixedSize()
                    .accessibilityIdentifier(cancelID ?? "auth_cancel_button")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MazidiColor.background)
    }
}

private struct AuthMessageSurface: View {
    let badge: (label: String, icon: String, kind: StatusBadge.Kind)
    let message: String
    let actionLabel: String
    let actionID: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: MazidiMetric.stackSpacing) {
            StatusBadge(kind: badge.kind, label: badge.label, systemImage: badge.icon)
            Text(message)
                .font(MazidiFont.body)
                .foregroundStyle(MazidiColor.text)
                .multilineTextAlignment(.center)
            Button(actionLabel, action: action)
                .buttonStyle(.mazidiPrimary)
                .accessibilityIdentifier(actionID)
        }
        .padding(MazidiMetric.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MazidiColor.background)
    }
}
