import SwiftUI

/// Honest offline / sync status (panel 4i). Never claims "synced" while items are pending;
/// every state pairs colour with a text label and an icon (non-colour signal). The badge is
/// a live accessibility value so VoiceOver announces changes.
struct SyncStatusView: View {
    let sync: ClientWorkoutModel.SyncPresentation

    var body: some View {
        StatusBadge(kind: descriptor.kind, label: descriptor.label, systemImage: descriptor.icon)
            .accessibilityIdentifier(A11yID.syncStatusBadge)
            .accessibilityLabel("Sync status")
            .accessibilityValue(descriptor.label)
    }

    private var descriptor: (kind: StatusBadge.Kind, label: String, icon: String) {
        switch sync {
        case .synced:
            return (.success, "Synced", "checkmark.icloud")
        case let .savedLocally(pending):
            return (.info, "Saved on this phone · \(pending) waiting", "iphone")
        case let .syncing(remaining):
            return (.info, "Syncing · \(remaining) left", "arrow.triangle.2.circlepath")
        case let .waitingForConnectivity(pending):
            return (.warning, "Waiting to sync · \(pending) item\(pending == 1 ? "" : "s")", "wifi.slash")
        case let .attentionNeeded(rejected):
            return (.danger, "Sync issue — needs attention (\(rejected))", "exclamationmark.triangle")
        case let .pausedAuthExpired(pending):
            return (.warning, "Sign in to sync · \(pending) waiting", "person.crop.circle.badge.exclamationmark")
        case let .sharingOff(pending):
            // Honest: sharing is off by the client's own choice, and what is recorded stays
            // saved on this phone. Never "Synced" and never "Waiting to sync".
            return pending > 0
                ? (.info, "Sharing off · \(pending) saved here", "person.crop.circle.badge.xmark")
                : (.info, "Sharing with your coach is off", "person.crop.circle.badge.xmark")
        }
    }
}

#if DEBUG
/// Development-only connectivity toggle so the honest offline → waiting → synced states can
/// be exercised without a backend. Compiled only in DEBUG (R-01/R-02) — it and its label
/// never exist in Release builds; the normal SyncStatusView is unaffected.
struct DevConnectivityToggle: View {
    @Bindable var model: ClientWorkoutModel

    var body: some View {
        Toggle(isOn: Binding(get: { model.isOnline }, set: { model.isOnline = $0 })) {
            Label("Simulated connection (dev)", systemImage: model.isOnline ? "wifi" : "wifi.slash")
                .font(MazidiFont.caption)
                .foregroundStyle(MazidiColor.textSecondary)
        }
        .tint(MazidiColor.primary)
        .accessibilityIdentifier(A11yID.devConnectivityToggle)
    }
}
#endif
