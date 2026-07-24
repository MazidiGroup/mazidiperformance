import Foundation
import MazidiFoundations

// ─────────────────────────────────────────────────────────────────────────────
//  Provider-neutral media-location contracts (ADR-0011 §3).
//  These value types describe WHAT a media asset is and WHERE a resolved copy of it
//  lives, without binding to any concrete provider, hostname, or filesystem layout.
//  Foundation-only; no networking, no CryptoKit (checksum hashing is injected so the
//  target stays cross-platform and package tests stay hermetic).
// ─────────────────────────────────────────────────────────────────────────────

/// Immutable media identity: slug + media type (`MediaKind`) + content version
/// (ADR-0010 §2). Its `objectKey` is the provider-neutral relative delivery key —
/// never a hostname, bucket, credential, or source filesystem path.
public struct MediaAssetID: Hashable, Sendable {
    public let slug: ExerciseSlug
    public let kind: MediaKind
    public let contentVersion: Int

    public init(slug: ExerciseSlug, kind: MediaKind, contentVersion: Int) {
        self.slug = slug
        self.kind = kind
        self.contentVersion = contentVersion
    }

    public var objectKey: String {
        MediaAssetRef.objectKey(slug: slug, kind: kind, contentVersion: contentVersion)
    }
}

/// Injected SHA-256 hasher. Kept as a seam so MazidiContent imports Foundation only
/// (no CryptoKit); the app supplies a CryptoKit-backed implementation, tests supply a
/// deterministic fake — no live crypto dependency leaks into the cross-platform target.
public protocol MediaChecksumHashing: Sendable {
    /// Lowercase hex SHA-256 of the bytes.
    func sha256Hex(_ data: Data) -> String
}

/// Immutable content checksum for a media asset (ADR-0010 §2/§8): SHA-256 + exact byte
/// size. Validation requires BOTH to match — size guards against truncation, hash
/// against corruption/substitution.
public struct MediaChecksum: Hashable, Sendable {
    public let sha256: String
    public let bytes: Int

    public init(sha256: String, bytes: Int) {
        self.sha256 = sha256
        self.bytes = bytes
    }

    public init(ref: MediaAssetRef) {
        self.init(sha256: ref.sha256, bytes: ref.bytes)
    }

    /// True only when the bytes match both the expected size and the expected hash.
    public func validates(_ data: Data, using hasher: any MediaChecksumHashing) -> Bool {
        data.count == bytes && hasher.sha256Hex(data).caseInsensitiveCompare(sha256) == .orderedSame
    }
}

/// The full addressing unit the fetcher and cache operate on: an immutable id bound to
/// its immutable checksum. The `objectKey` (checksum-pinned by version) is the cache key
/// and the remote key — a new `contentVersion` is a different key, so stale content is
/// impossible by construction (ADR-0010 §8, ADR-0011 §5).
public struct MediaLocator: Hashable, Sendable {
    public let id: MediaAssetID
    public let checksum: MediaChecksum

    public init(id: MediaAssetID, checksum: MediaChecksum) {
        self.id = id
        self.checksum = checksum
    }

    /// Build from a catalogue/manifest media ref for a slug.
    public init(slug: ExerciseSlug, ref: MediaAssetRef) {
        self.id = MediaAssetID(slug: slug, kind: ref.kind, contentVersion: ref.contentVersion)
        self.checksum = MediaChecksum(ref: ref)
    }

    public var objectKey: String { id.objectKey }
}

/// A resolved, provider-neutral location for a media asset — one of the local/remote
/// tiers the resolver composes (ADR-0011 §4). It carries a URL only after resolution;
/// the domain never stores a concrete URL.
public enum MediaLocation: Sendable, Equatable {
    /// Approved representative asset shipped in the app bundle.
    case bundled(URL)
    /// A validated entry in the bounded on-disk cache.
    case cached(URL)
    /// The injected remote origin joined with the asset's object key.
    case remote(URL)

    public var url: URL {
        switch self {
        case let .bundled(url), let .cached(url), let .remote(url): url
        }
    }
}

/// The injected remote origin (ADR-0010 §6, ADR-0011 §3/§6). Built from `MEDIA_BASE_URL`
/// configuration; an absent/empty/invalid value yields `nil`, disabling the remote tier
/// honestly (ADR-0011 §4 tier 3) rather than crashing. Never carries credentials.
public struct RemoteMediaOrigin: Hashable, Sendable {
    public let baseURL: URL

    public init(baseURL: URL) { self.baseURL = baseURL }

    /// From injected configuration. Returns nil for missing/empty/whitespace or a value
    /// without a URL scheme (e.g. a stray path), so the caller can treat "no origin" as
    /// "remote tier disabled".
    public init?(configuredBaseURL string: String?) {
        guard
            let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            let url = URL(string: trimmed),
            url.scheme != nil
        else { return nil }
        self.baseURL = url
    }

    /// The absolute URL for a locator: origin + provider-neutral relative object key.
    public func url(for locator: MediaLocator) -> URL {
        baseURL.appendingPathComponent(locator.objectKey)
    }
}
