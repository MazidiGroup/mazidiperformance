import Foundation

/// Pure rest-timer arithmetic (panel 4a). No scheduling — the UI layer drives ticks; this
/// model stays deterministic and testable, and supports the accessible numeric countdown
/// required under Reduce Motion (14f: numeric countdown instead of animated ring).
public struct RestTimer: Sendable, Codable, Equatable {
    public let durationSeconds: Int
    public private(set) var startedAt: Date
    /// Accumulated pause before the current run segment.
    private var accumulatedPause: TimeInterval
    private var pausedAt: Date?

    public init(durationSeconds: Int, startedAt: Date) {
        self.durationSeconds = durationSeconds
        self.startedAt = startedAt
        self.accumulatedPause = 0
        self.pausedAt = nil
    }

    public var isPaused: Bool { pausedAt != nil }

    public mutating func pause(at date: Date) {
        guard pausedAt == nil else { return }
        pausedAt = date
    }

    public mutating func resume(at date: Date) {
        guard let p = pausedAt else { return }
        accumulatedPause += date.timeIntervalSince(p)
        pausedAt = nil
    }

    /// Add time (e.g. "+30 s" control).
    public mutating func extend(by seconds: Int) -> RestTimer {
        RestTimer(durationSeconds: durationSeconds + seconds, startedAt: startedAt)
            .carryingPause(from: self)
    }

    private func carryingPause(from other: RestTimer) -> RestTimer {
        var copy = self
        copy.accumulatedPause = other.accumulatedPause
        copy.pausedAt = other.pausedAt
        return copy
    }

    public func remainingSeconds(at date: Date) -> Int {
        let reference = pausedAt ?? date
        let elapsed = reference.timeIntervalSince(startedAt) - accumulatedPause
        return max(0, durationSeconds - Int(elapsed.rounded(.down)))
    }

    public func isFinished(at date: Date) -> Bool { remainingSeconds(at: date) == 0 }

    /// Text equivalent for VoiceOver announcements ("Rest: 45 seconds remaining").
    public func accessibilityDescription(at date: Date) -> String {
        "Rest: \(remainingSeconds(at: date)) seconds remaining"
    }
}
