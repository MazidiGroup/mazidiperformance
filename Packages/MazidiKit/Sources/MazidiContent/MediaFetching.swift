import Foundation
import MazidiFoundations

// ─────────────────────────────────────────────────────────────────────────────
//  Injected media-fetching boundary (ADR-0011 §6).
//  The domain never imports a networking SDK; media retrieval is an injected protocol
//  with typed failures, cancellation, no internal retry loops, and stale-request
//  (version) protection. A deterministic fake fetcher backs tests and previews — no
//  live network is ever used in package or UI tests.
// ─────────────────────────────────────────────────────────────────────────────

/// Exhaustive, typed fetch failures — no untyped `Error` leaks to callers.
public enum MediaFetchError: Error, Equatable, Sendable {
    /// No connectivity / origin unreachable.
    case unreachable
    /// Origin reachable but the object does not exist.
    case notFound
    /// Bytes arrived but failed checksum validation — discarded, never served.
    case checksumMismatch
    /// The request was cancelled or superseded by a newer version (stale-request).
    case cancelled
    /// Bytes arrived and matched size/hash but could not be decoded as media.
    case decode
}

/// The injected retrieval seam. Implementations MUST NOT retry internally (no hot
/// loops — a failure returns to the caller), MUST honour cancellation, and MUST never
/// return unvalidated bytes as success. A real (backend-era) implementation validates
/// against `locator.checksum`; the deterministic fake is configured per object key.
public protocol MediaFetching: Sendable {
    func fetch(_ locator: MediaLocator, from origin: RemoteMediaOrigin) async -> Result<Data, MediaFetchError>
}

/// Serialises requests per media surface (slug + kind) and applies stale-request/version
/// protection (ADR-0011 §6): if a newer content version was requested while an older
/// fetch was outstanding, the older, superseded response is discarded (`.cancelled`)
/// rather than shown. Does no retrying of its own.
public actor MediaRequestCoordinator {
    private struct SurfaceKey: Hashable {
        let slug: ExerciseSlug
        let kind: MediaKind
    }

    private let fetcher: any MediaFetching
    private var latestRequestedVersion: [SurfaceKey: Int] = [:]

    public init(fetcher: any MediaFetching) {
        self.fetcher = fetcher
    }

    public func fetch(_ locator: MediaLocator, from origin: RemoteMediaOrigin) async -> Result<Data, MediaFetchError> {
        let key = SurfaceKey(slug: locator.id.slug, kind: locator.id.kind)
        let requested = locator.id.contentVersion
        latestRequestedVersion[key] = max(latestRequestedVersion[key] ?? 0, requested)

        let result = await fetcher.fetch(locator, from: origin)

        // If a newer version was requested for this surface while this fetch was in
        // flight (or before it), the response is stale — discard it, don't show it.
        if let newest = latestRequestedVersion[key], newest > requested {
            return .failure(.cancelled)
        }
        return result
    }
}

/// Deterministic, in-memory fetcher for tests and previews. Never touches the network:
/// it returns configured bytes or a configured typed failure keyed by object key, and
/// honours task cancellation. Reproducible run-to-run.
public struct DeterministicMediaFetcher: MediaFetching {
    private let bytesByObjectKey: [String: Data]
    private let failuresByObjectKey: [String: MediaFetchError]

    public init(
        bytesByObjectKey: [String: Data] = [:],
        failuresByObjectKey: [String: MediaFetchError] = [:]
    ) {
        self.bytesByObjectKey = bytesByObjectKey
        self.failuresByObjectKey = failuresByObjectKey
    }

    public func fetch(_ locator: MediaLocator, from _: RemoteMediaOrigin) async -> Result<Data, MediaFetchError> {
        if Task.isCancelled { return .failure(.cancelled) }
        let key = locator.objectKey
        if let failure = failuresByObjectKey[key] { return .failure(failure) }
        guard let data = bytesByObjectKey[key] else { return .failure(.notFound) }
        return .success(data)
    }
}
