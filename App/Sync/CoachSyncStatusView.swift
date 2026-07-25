import SwiftUI

/// Minimal, honest account-level sync status for the Coach shell (ADR-0012 §10). Never
/// claims "delivered"/"synced" while items are pending; pairs colour with text + icon
/// (non-colour signal). Assignment delivery/receipt is surfaced separately and stays
/// "Queued — delivery confirms with backend" (ADR-0009) — this is the outbox-level truth.
struct CoachSyncStatusView: View {
    let status: CoachProgrammingModel.SyncStatus

    var body: some View {
        StatusBadge(kind: descriptor.kind, label: descriptor.label, systemImage: descriptor.icon)
            .accessibilityIdentifier("coach_sync_status")
            .accessibilityLabel("Sync status")
            .accessibilityValue(descriptor.label)
    }

    private var descriptor: (kind: StatusBadge.Kind, label: String, icon: String) {
        switch status {
        case .upToDate:
            return (.success, "Up to date", "checkmark.icloud")
        case let .savedLocally(pending):
            return (.info, "Saved on this phone · \(pending) queued", "arrow.triangle.2.circlepath")
        case let .offline(pending):
            return (.warning, "Offline · \(pending) queued", "wifi.slash")
        }
    }
}
