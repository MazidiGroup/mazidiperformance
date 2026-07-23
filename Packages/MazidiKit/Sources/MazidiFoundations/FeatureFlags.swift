import Foundation

/// Feature flags gate incomplete work, never product/safety rules.
/// (e.g. the draft-content review badge is a product rule and has no flag.)
public enum FeatureFlag: String, CaseIterable, Sendable {
    case clientWorkoutSlice = "client_workout_slice"
    case coachProgrammingLoop = "coach_programming_loop"
    case syncEngine = "sync_engine"
}

public protocol FeatureFlagProviding: Sendable {
    func isEnabled(_ flag: FeatureFlag) -> Bool
}

/// Static in-code defaults; a remote-config-backed provider can replace this later.
public struct DefaultFeatureFlags: FeatureFlagProviding {
    private let enabled: Set<FeatureFlag>

    public init(enabled: Set<FeatureFlag> = [.clientWorkoutSlice, .syncEngine]) {
        self.enabled = enabled
    }

    public func isEnabled(_ flag: FeatureFlag) -> Bool { enabled.contains(flag) }
}
