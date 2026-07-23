import Foundation

/// Injectable time source so domain logic and tests never read the wall clock directly.
public protocol AppClock: Sendable {
    func now() -> Date
}

public struct SystemClock: AppClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Deterministic clock for tests.
public final class FixedClock: AppClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_784_000_000)) {
        self.current = start
    }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}
