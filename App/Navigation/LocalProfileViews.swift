#if LOCAL_IDENTITY
import SwiftUI
import MazidiAuth

/// Honest labelling for the local test profile (ADR-0014). These surfaces exist only in
/// `LOCAL_IDENTITY` builds (Debug + Staging/TestFlight) and never call the profile an
/// account or a sign-in: it is a device-local profile, with no verification and no sync.
enum LocalProfileCopy {
    static func roleName(_ role: RoleClaim) -> String {
        switch role {
        case .coach: return "Coach"
        case .client: return "Client"
        }
    }

    /// One sentence, used verbatim wherever the profile is visible, so the limitation is
    /// stated the same way every time.
    static let limitation = "No sign-in and no account. Everything stays on this phone and nothing is synced or shared."
}

// MARK: - First-launch role choice

/// Role picker shown on the signed-out surface. A single local user on one device maps to
/// one role at a time (ADR-0008 §7), so the tester chooses which shell to open and can
/// switch later — that is the only way both shells can be exercised on a test build.
struct LocalProfileChooser: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
            Text("Local test profile")
                .font(MazidiFont.sectionTitle)
                .foregroundStyle(MazidiColor.text)
                .accessibilityAddTraits(.isHeader)

            StatusBadge(
                kind: .info,
                label: "Test build · this device only",
                systemImage: "iphone"
            )
            .accessibilityIdentifier("local_profile_state_badge")

            Text(LocalProfileCopy.limitation + " Choose which side of the app to open; you can switch afterwards.")
                .font(MazidiFont.callout)
                .foregroundStyle(MazidiColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                // Stable marker for the local-profile signed-out surface.
                .accessibilityIdentifier("state_local_profile_chooser")

            Button("Continue as Coach") {
                Task { await session.continueAsLocalProfile(role: .coach) }
            }
            .buttonStyle(.mazidiPrimary)
            .accessibilityIdentifier("local_profile_continue_coach")
            .accessibilityHint("Opens the coach side of the app with a local test profile")

            Button("Continue as Client") {
                Task { await session.continueAsLocalProfile(role: .client) }
            }
            .buttonStyle(.mazidiPrimary)
            .accessibilityIdentifier("local_profile_continue_client")
            .accessibilityHint("Opens the client side of the app with a local test profile")
        }
        .padding(MazidiMetric.cardPadding)
        .background(
            MazidiColor.surface,
            in: RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous)
                .strokeBorder(MazidiColor.hairline, lineWidth: 1)
        )
        .padding(.horizontal, MazidiMetric.screenPadding)
    }
}

// MARK: - Shell wrapper

/// Wraps a role shell with the local-profile banner. The banner takes its own row in a
/// plain vertical stack rather than a `safeAreaInset`: an inset applied outside the shell's
/// `NavigationStack` does not reach the scroll views on pushed screens, so the banner ended
/// up sitting *over* their last control instead of above it. Splitting the space shrinks
/// the shell's frame, so every screen inside lays out and scrolls within what is left.
///
/// Applied only at the `LOCAL_IDENTITY` call sites in `SessionRootView`; the banner appears
/// only while the active session actually is a local test profile.
struct LocalProfileShell<Content: View>: View {
    @Environment(SessionModel.self) private var session
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let role = session.localProfileRole {
                LocalProfileBanner(role: role)
            }
        }
    }
}

// MARK: - Persistent honest label inside the shells

/// Bottom strip shown inside both shells while a local test profile is active. It states
/// what the profile is and offers the role switch. Laid out as a vertical stack so it
/// restacks rather than clipping at AX5; status is carried by text and an SF Symbol, never
/// by colour alone.
struct LocalProfileBanner: View {
    @Environment(SessionModel.self) private var session
    let role: RoleClaim

    private var otherRole: RoleClaim { role == .coach ? .client : .coach }

    var body: some View {
        VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
            StatusBadge(
                kind: .info,
                label: "Local test profile · \(LocalProfileCopy.roleName(role))",
                systemImage: "iphone"
            )

            Text(LocalProfileCopy.limitation)
                .font(MazidiFont.caption)
                .foregroundStyle(MazidiColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Switch to \(LocalProfileCopy.roleName(otherRole))") {
                Task { await session.switchLocalRole(to: otherRole) }
            }
            .buttonStyle(.mazidiSecondary)
            .accessibilityIdentifier("local_profile_switch_role")
            .accessibilityLabel("Switch local test profile to \(LocalProfileCopy.roleName(otherRole))")
            .accessibilityHint("Closes this side of the app and opens the other one. Nothing is deleted.")
        }
        .padding(.horizontal, MazidiMetric.screenPadding)
        .padding(.vertical, MazidiMetric.tightSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MazidiColor.surfaceAlt)
        .overlay(alignment: .top) {
            Rectangle().fill(MazidiColor.hairline).frame(height: 1)
        }
        // No accessibility modifier on this container: applying one merges the badge, the
        // explanation and the switch control into a single element, which hides the button
        // from VoiceOver navigation (and from UI tests) rather than helping.
    }
}
#endif
