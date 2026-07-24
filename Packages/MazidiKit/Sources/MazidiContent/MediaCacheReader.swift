import Foundation

// ─────────────────────────────────────────────────────────────────────────────
//  Synchronous validated cache read for the presentation path (ADR-0011 §4/§5).
//  The `MediaCache` actor owns writes/eviction/LRU (async); presentation needs a
//  synchronous, always-validated read. This reader re-hashes the on-disk bytes and
//  serves the file ONLY when it exists AND its size AND its SHA-256 match the locator's
//  checksum — so a corrupt or same-size-tampered entry is NEVER presented. Reads are
//  safe against the immutable, content-addressed cache directory.
// ─────────────────────────────────────────────────────────────────────────────

public struct MediaCacheReader: Sendable {
    private let directory: URL
    private let hasher: any MediaChecksumHashing

    public init(directory: URL, hasher: any MediaChecksumHashing) {
        self.directory = directory
        self.hasher = hasher
    }

    /// The cached file URL for a locator, but only when the on-disk bytes fully validate
    /// against the locator checksum (size + SHA-256). Returns nil for missing, wrong-size,
    /// or tampered files — the caller then falls back to the next tier. Never returns an
    /// unvalidated file.
    public func validatedURL(for locator: MediaLocator) -> URL? {
        let url = directory.appendingPathComponent(MediaCache.filename(forObjectKey: locator.objectKey))
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard locator.checksum.validates(data, using: hasher) else { return nil }
        return url
    }
}
