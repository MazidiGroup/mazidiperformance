import SwiftUI

/// Semantic colour tokens from `design/handoff-current/handoff/design-tokens.md`.
/// These are the ONLY colour source in the app — no hard-coded colours in views.
/// Dark/light pairs come straight from the token table; status colours are always paired
/// with a text label (and an icon under Differentiate Without Colour) — colour is never
/// the only signal.
enum MazidiColor {
    // Backgrounds & surfaces
    static let background = dynamic(dark: 0x0D0E11, light: 0xF2F2F6)
    static let surface = dynamic(dark: 0x17181D, light: 0xFFFFFF)
    static let surfaceAlt = dynamic(dark: 0x1B1D23, light: 0xFFFFFF)
    static let sheet = dynamic(dark: 0x15161B, light: 0xFFFFFF)

    // Text
    static let text = dynamic(dark: 0xF4F5F7, light: 0x17181D)
    static let textSecondary = Color(
        light: Color(hex: 0x17181D).opacity(0.62),
        dark: Color(hex: 0xEBECF5).opacity(0.66)
    )
    static let textTertiary = Color(
        light: Color(hex: 0x17181D).opacity(0.50),
        dark: Color(hex: 0xEBECF5).opacity(0.52)
    )

    // Actions
    static let primary = dynamic(dark: 0x2F66D8, light: 0x2F66D8)
    static let accentSmall = dynamic(dark: 0x3A7BFD, light: 0x2F66D8)
    static let link = dynamic(dark: 0x8FB2FE, light: 0x2456C4)

    // Status — light success is #136B41 per the accessibility patch (14i)
    static let successText = dynamic(dark: 0x7BDCA8, light: 0x136B41)
    static let successTint = Color(
        light: Color(hex: 0x38C97C).opacity(0.10),
        dark: Color(hex: 0x38C97C).opacity(0.14)
    )
    static let warningText = dynamic(dark: 0xEFC684, light: 0x8A5A00)
    static let warningTint = Color(
        light: Color(hex: 0xE8A33D).opacity(0.12),
        dark: Color(hex: 0xE8A33D).opacity(0.14)
    )
    static let dangerText = dynamic(dark: 0xF08A8E, light: 0xC0353A)
    static let dangerTint = Color(
        light: Color(hex: 0xE5484D).opacity(0.10),
        dark: Color(hex: 0xE5484D).opacity(0.14)
    )

    static let hairline = Color(
        light: Color(hex: 0x111217).opacity(0.09),
        dark: Color.white.opacity(0.075)
    )

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(light: Color(hex: light), dark: Color(hex: dark))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Appearance-adaptive colour that also respects the token rule that switching
    /// appearance swaps tokens only.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}
