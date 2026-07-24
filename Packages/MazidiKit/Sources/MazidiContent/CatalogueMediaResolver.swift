import Foundation
import MazidiFoundations

// ─────────────────────────────────────────────────────────────────────────────
//  Composed media resolution (ADR-0011 §4). One deterministic path replaces the
//  fixture/production divergence:
//    1. validated cached asset (matching id + checksum)   ← MediaCacheReader
//    2. approved bundled representative asset               ← BundledMediaLocating
//    3. injected remote URL (async download path only)      ← RemoteMediaOrigin
//    4. poster-only / 5. name+icon unavailable              ← handled by the view
//  Synchronous `posterURL`/`clipURL` return a LOCAL url (tier 1 or 2) for immediate
//  presentation; the remote tier is exposed separately for the async download path and
//  is never used to block a render. Foundation-only; the app adapts it to its own
//  `MediaResolving` seam.
// ─────────────────────────────────────────────────────────────────────────────

/// App-provided lookup for the approved bundled representative media set.
public protocol BundledMediaLocating: Sendable {
    func bundledURL(for slug: ExerciseSlug, kind: MediaKind) -> URL?
}

public struct CatalogueMediaResolver: Sendable {
    private let manifest: MediaManifestStore
    private let cacheReader: MediaCacheReader?
    private let bundled: any BundledMediaLocating
    private let remoteOrigin: RemoteMediaOrigin?

    public init(
        manifest: MediaManifestStore,
        cacheReader: MediaCacheReader?,
        bundled: any BundledMediaLocating,
        remoteOrigin: RemoteMediaOrigin? = nil
    ) {
        self.manifest = manifest
        self.cacheReader = cacheReader
        self.bundled = bundled
        self.remoteOrigin = remoteOrigin
    }

    /// A resolved LOCAL location for immediate presentation (tier 1 → tier 2), or nil when
    /// no local copy validates (the view then renders poster-only or name+icon).
    public func localLocation(for slug: ExerciseSlug, kind: MediaKind) -> MediaLocation? {
        if let cacheReader, let locator = manifest.locator(for: slug, kind: kind),
           let url = cacheReader.validatedURL(for: locator) {
            return .cached(url)
        }
        if let url = bundled.bundledURL(for: slug, kind: kind) {
            return .bundled(url)
        }
        return nil
    }

    public func posterURL(for slug: ExerciseSlug) -> URL? { localLocation(for: slug, kind: .poster)?.url }
    public func clipURL(for slug: ExerciseSlug) -> URL? { localLocation(for: slug, kind: .video)?.url }

    /// The remote URL to fetch when local tiers miss AND an origin is configured — used by
    /// the async download path only, never for synchronous presentation. Nil when no
    /// origin is configured (the honestly-inert state until a backend exists) or the
    /// manifest has no such asset.
    public func remoteURL(for slug: ExerciseSlug, kind: MediaKind) -> URL? {
        guard let remoteOrigin, let locator = manifest.locator(for: slug, kind: kind) else { return nil }
        return remoteOrigin.url(for: locator)
    }

    /// The locator (id + checksum) for a slug's media, for the download/cache path.
    public func locator(for slug: ExerciseSlug, kind: MediaKind) -> MediaLocator? {
        manifest.locator(for: slug, kind: kind)
    }
}
