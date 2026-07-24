import Foundation
import MazidiFoundations

// Canonical slug format (ADR-0010 §1): lowercase ASCII letters, digits, single
// hyphens between runs — `^[a-z0-9]+(-[a-z0-9]+)*$`. Implemented by hand (not
// NSRegularExpression) so the rule is identical on every Swift toolchain CI uses.

extension ExerciseSlug {
    /// True when the raw value is in canonical catalogue format. The audit tool
    /// rejects non-canonical slugs; known misspellings that *are* canonical in
    /// format (e.g. `parralel-bar-dips`) stay valid — renaming is forbidden.
    public var isCanonicalFormat: Bool { Self.isCanonicalFormat(rawValue) }

    public static func isCanonicalFormat(_ raw: String) -> Bool {
        guard !raw.isEmpty, !raw.hasPrefix("-"), !raw.hasSuffix("-") else { return false }
        var previousWasHyphen = false
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9":
                previousWasHyphen = false
            case "-":
                if previousWasHyphen { return false }
                previousWasHyphen = true
            default:
                return false
            }
        }
        return true
    }
}
