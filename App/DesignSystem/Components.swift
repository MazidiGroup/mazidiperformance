import SwiftUI

// MARK: - Card container

/// Standard tokened card surface (radius 14–16, hairline border).
struct MazidiCard<Content: View>: View {
    var padding: CGFloat = MazidiMetric.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MazidiColor.surface, in: RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous)
                    .strokeBorder(MazidiColor.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Status badge (colour is never the only signal)

/// A status pill that always pairs its tint with a text label and an SF Symbol, so meaning
/// survives Differentiate Without Colour and greyscale (design-tokens.md / 14e).
struct StatusBadge: View {
    enum Kind { case neutral, success, warning, danger, info }
    let kind: Kind
    let label: String
    var systemImage: String?

    private var textColor: Color {
        switch kind {
        case .neutral: return MazidiColor.textSecondary
        case .success: return MazidiColor.successText
        case .warning: return MazidiColor.warningText
        case .danger: return MazidiColor.dangerText
        case .info: return MazidiColor.link
        }
    }

    private var tint: Color {
        switch kind {
        case .neutral: return MazidiColor.hairline
        case .success: return MazidiColor.successTint
        case .warning: return MazidiColor.warningTint
        case .danger: return MazidiColor.dangerTint
        case .info: return MazidiColor.primary.opacity(0.14)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(label)
        }
        .font(MazidiFont.badge)
        .foregroundStyle(textColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint, in: Capsule())
        // Merge icon + text into one VoiceOver stop reading just the label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Draft-content badge — a product rule, never gated by a flag (functional-rules.md).
struct DraftBadge: View {
    var body: some View {
        StatusBadge(kind: .warning, label: "DRAFT COPY · PENDING REVIEW", systemImage: "pencil.and.outline")
            .accessibilityLabel("Draft copy, pending review")
    }
}

// MARK: - Buttons (44pt minimum target enforced)

struct MazidiPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MazidiFont.bodyEmphasis)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: MazidiMetric.minTarget)
            .background(
                MazidiColor.primary.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4),
                in: RoundedRectangle(cornerRadius: MazidiMetric.buttonRadius, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

struct MazidiSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MazidiFont.bodyEmphasis)
            .foregroundStyle(MazidiColor.link)
            .frame(maxWidth: .infinity, minHeight: MazidiMetric.minTarget)
            .background(
                MazidiColor.surfaceAlt.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: MazidiMetric.buttonRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MazidiMetric.buttonRadius, style: .continuous)
                    .strokeBorder(MazidiColor.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == MazidiPrimaryButtonStyle {
    static var mazidiPrimary: MazidiPrimaryButtonStyle { .init() }
}
extension ButtonStyle where Self == MazidiSecondaryButtonStyle {
    static var mazidiSecondary: MazidiSecondaryButtonStyle { .init() }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(MazidiFont.sectionTitle)
            .foregroundStyle(MazidiColor.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Loading / empty / error state views

/// Loading skeleton — a soft placeholder block, never a black box (asset rules 7i).
struct SkeletonBlock: View {
    var height: CGFloat = 16
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(MazidiColor.surfaceAlt)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// Shared empty / error presentation with an icon, message, and optional retry.
struct MessageState: View {
    let systemImage: String
    let title: String
    var message: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: MazidiMetric.stackSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(MazidiColor.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(MazidiFont.sectionTitle)
                .foregroundStyle(MazidiColor.text)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.mazidiSecondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(MazidiMetric.screenPadding)
    }
}
