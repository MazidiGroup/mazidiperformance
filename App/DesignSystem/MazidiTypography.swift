import SwiftUI

/// Typography + metric tokens from `design/handoff-current/handoff/design-tokens.md`.
///
/// Every font is built on a SwiftUI **text style**, so all text scales with Dynamic Type
/// (through AX5) and steps up a weight under Bold Text automatically — the accessibility
/// acceptance criteria (14c/14i). No fixed point sizes are used for body copy.
enum MazidiFont {
    /// Screen titles (17–30px band).
    static let screenTitle = Font.title2.weight(.bold)
    static let sectionTitle = Font.headline
    static let body = Font.body
    static let bodyEmphasis = Font.body.weight(.semibold)
    static let callout = Font.callout
    static let caption = Font.caption
    /// Large numeric read-outs (rest countdown, set counts) — rounded, monospaced digits so
    /// the value never reflows as it changes.
    static let timerDisplay = Font.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit()
    static let metricValue = Font.system(.title, design: .rounded).weight(.semibold).monospacedDigit()
    static let badge = Font.caption2.weight(.semibold)
}

/// Corner radii, spacing and the 44pt minimum-target constant.
enum MazidiMetric {
    static let cardRadius: CGFloat = 16
    static let sheetRadius: CGFloat = 24
    static let chipRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 14
    /// Minimum interactive target at every type size (14i acceptance criterion).
    static let minTarget: CGFloat = 44
    static let screenPadding: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let stackSpacing: CGFloat = 12
    static let tightSpacing: CGFloat = 8
}
