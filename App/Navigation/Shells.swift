import SwiftUI
import MazidiAuth

/// Signed-out surface. Production sign-in arrives with the backend contract (R-01) —
/// stated honestly, not simulated. In DEBUG builds only, deterministic development
/// identities (ADR-0008 §6) provide real coordinator sign-ins for development, previews
/// and UI tests; none of this exists in Release.
struct SignInView: View {
    @Environment(SessionModel.self) private var session
    let pendingRemoteRevocation: Bool

    var body: some View {
        VStack(spacing: MazidiMetric.stackSpacing) {
            Spacer()
            Text("Mazidi Performance")
                .font(.largeTitle.bold())
                .foregroundStyle(MazidiColor.text)
            Text("Sign-in arrives with the backend contract.")
                .foregroundStyle(MazidiColor.textSecondary)
                // Stable app-state marker so UI tests can wait for the signed-out surface
                // deterministically rather than inferring it from a control's presence.
                .accessibilityIdentifier("state_signed_out")

            if pendingRemoteRevocation {
                StatusBadge(
                    kind: .warning,
                    label: "Signed out on this phone · other devices update when back online",
                    systemImage: "wifi.slash"
                )
                .accessibilityIdentifier("pending_remote_revocation_badge")
            }

            #if DEBUG
            VStack(spacing: MazidiMetric.tightSpacing) {
                Text("Development accounts (DEBUG only)")
                    .font(MazidiFont.caption)
                    .foregroundStyle(MazidiColor.textTertiary)
                Button("Continue as Client (dev)") {
                    Task { await session.signIn(devIdentity: "dev-client-001") }
                }
                .buttonStyle(.mazidiPrimary)
                .accessibilityIdentifier("dev_continue_client")
                Button("Continue as Client 2 (dev)") {
                    Task { await session.signIn(devIdentity: "dev-client-002") }
                }
                .buttonStyle(.mazidiSecondary)
                .accessibilityIdentifier("dev_continue_client_2")
                Button("Continue as Coach (dev)") {
                    Task { await session.signIn(devIdentity: "dev-coach-001") }
                }
                .buttonStyle(.mazidiSecondary)
                .accessibilityIdentifier("dev_continue_coach")
            }
            .padding(.horizontal, MazidiMetric.screenPadding)
            #endif
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MazidiColor.background)
    }
}

/// Coach shell — reached ONLY through a validated coach role claim. Hosts the
/// programming flow (ADR-0009) over the session-owned coach environment.
struct CoachShellView: View {
    @Environment(SessionModel.self) private var session
    let accountLabel: String

    var body: some View {
        if let environment = session.coachEnvironment {
            VStack(spacing: 0) {
                CoachRootView(environment: environment)
                    .id(ObjectIdentifier(environment)) // fresh navigation per account
                #if DEBUG
                // Dev-only identity label (fixture ids). Real coach profile surfaces
                // arrive with turn 13b; raw subject ids are never rendered in Release.
                Text("Signed in: \(accountLabel)")
                    .font(MazidiFont.caption)
                    .foregroundStyle(MazidiColor.textTertiary)
                    .accessibilityIdentifier("coach_account_label")
                    .padding(.bottom, 4)
                #endif
            }
            .background(MazidiColor.background)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
