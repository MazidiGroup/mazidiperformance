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

/// Coach shell — reached ONLY through a validated coach role claim. Coach features land
/// in later phases; the shell provides the account surface and sign-out.
struct CoachShellView: View {
    @Environment(SessionModel.self) private var session
    let accountLabel: String

    var body: some View {
        NavigationStack {
            VStack(spacing: MazidiMetric.stackSpacing) {
                Text("Coach dashboard — phase 4")
                    .foregroundStyle(MazidiColor.textSecondary)
                #if DEBUG
                // Dev-only identity label (fixture ids). Real coach profile surfaces
                // arrive with turn 13b; raw subject ids are never rendered in Release.
                Text("Signed in: \(accountLabel)")
                    .font(MazidiFont.caption)
                    .foregroundStyle(MazidiColor.textTertiary)
                    .accessibilityIdentifier("coach_account_label")
                #endif
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { Task { await session.signOut() } }
                        .accessibilityIdentifier("coach_sign_out")
                }
            }
        }
    }
}
