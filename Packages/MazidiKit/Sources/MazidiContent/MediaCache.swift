import Foundation

// ─────────────────────────────────────────────────────────────────────────────
//  Bounded, validated, device-global media cache (ADR-0010 §8, ADR-0011 §5).
//
//  Key = the immutable, checksum-pinned object key (a new content version is a
//  different key, so stale content is impossible by construction). Admission
//  validates bytes against the manifest checksum and promotes atomically (temp file
//  → rename); partial/failed/corrupt bytes are never admitted or served. Bounded by a
//  byte budget (default 512 MB) with deterministic LRU eviction that removes videos
//  before posters and never evicts a currently-presented file. Cache failure returns
//  nil — it never throws into a render/execution path.
//
//  Privacy: the cache is DEVICE-GLOBAL (immutable, non-private, shared exercise media)
//  and its paths + in-memory metadata are derived ONLY from the object key
//  (slug / media type / version). No raw account id and no user/workout content ever
//  appears in a path or in metadata (ADR-0011 §5). Foundation-only; SHA-256 hashing is
//  injected so the target stays cross-platform and tests stay hermetic.
// ─────────────────────────────────────────────────────────────────────────────

public actor MediaCache {
    /// Byte-budget policy. Default 512 MB (ADR-0010 §8).
    public struct Limits: Sendable {
        public var maxBytes: Int
        public init(maxBytes: Int = 512 * 1024 * 1024) { self.maxBytes = maxBytes }
    }

    private struct Entry {
        let kind: MediaKind
        var bytes: Int
        var access: UInt64
    }

    /// Prefix for in-progress download temp files; cleaned up on init (interrupted
    /// downloads) and never served.
    private static let tempPrefix = ".dl-"

    private let directory: URL
    private let hasher: any MediaChecksumHashing
    private let fileManager: FileManager
    private let limits: Limits

    private var index: [String: Entry] = [:]   // objectKey → entry
    private var presented: Set<String> = []     // object keys that must not be evicted
    private var totalBytes = 0
    private var accessClock: UInt64 = 0

    /// Opens (creating if needed) a cache rooted at `directory`. Rebuilds its index from
    /// whatever is already on disk (so cached media survives relaunch and is usable
    /// offline) and removes any interrupted-download temp files.
    public init(
        directory: URL,
        hasher: any MediaChecksumHashing,
        limits: Limits = Limits(),
        fileManager: FileManager = .default
    ) throws {
        self.directory = directory
        self.hasher = hasher
        self.fileManager = fileManager
        self.limits = limits
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // No .skipsHiddenFiles: temp files are dot-prefixed (".dl-…") and must be seen so
        // interrupted downloads can be cleaned up here.
        if let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) {
            for url in Self.sortedByName(entries) {
                let name = url.lastPathComponent
                if name.hasPrefix(Self.tempPrefix) {
                    try? fileManager.removeItem(at: url)   // interrupted download — discard
                    continue
                }
                let key = Self.objectKey(fromFilename: name)
                guard let kind = Self.kind(forObjectKey: key),
                      let size = Self.fileSize(url) else { continue }
                accessClock += 1
                index[key] = Entry(kind: kind, bytes: size, access: accessClock)
                totalBytes += size
            }
        }
    }

    /// Device-global cache directory: `Library/Caches/MazidiPerformance/exercise-media`.
    /// Contains no account id by construction (ADR-0011 §5).
    public static func deviceGlobalDirectory(fileManager: FileManager = .default) throws -> URL {
        let caches = try fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return caches
            .appendingPathComponent("MazidiPerformance", isDirectory: true)
            .appendingPathComponent("exercise-media", isDirectory: true)
    }

    // MARK: - Admission (validate → atomic promote)

    /// Validate `data` against the locator's checksum and, on success, promote it into
    /// the cache atomically (temp file → rename). Returns the cached file URL, or nil if
    /// the bytes fail validation or any file operation fails — never throws, so a cache
    /// failure cannot block rendering/execution. Unvalidated bytes are never admitted.
    @discardableResult
    public func admit(_ locator: MediaLocator, data: Data) -> URL? {
        guard locator.checksum.validates(data, using: hasher) else { return nil }

        let key = locator.objectKey
        let finalURL = fileURL(for: key)
        let tempURL = directory.appendingPathComponent(Self.tempPrefix + UUID().uuidString)
        do {
            try data.write(to: tempURL, options: .atomic)
            if fileManager.fileExists(atPath: finalURL.path) {
                try? fileManager.removeItem(at: finalURL)
                if let old = index[key] { totalBytes -= old.bytes; index[key] = nil }
            }
            try fileManager.moveItem(at: tempURL, to: finalURL)   // atomic promotion
        } catch {
            try? fileManager.removeItem(at: tempURL)              // clean the partial temp
            return nil
        }
        accessClock += 1
        index[key] = Entry(kind: locator.id.kind, bytes: data.count, access: accessClock)
        totalBytes += data.count
        enforceBudget()
        return finalURL
    }

    // MARK: - Reads

    /// The cached file URL for a locator when a valid entry exists, bumping its LRU
    /// recency. A missing or size-changed file drops the stale entry and returns nil.
    public func cachedURL(for locator: MediaLocator) -> URL? {
        let key = locator.objectKey
        guard let entry = index[key] else { return nil }
        let url = fileURL(for: key)
        guard let size = Self.fileSize(url), size == entry.bytes else {
            remove(key: key)
            return nil
        }
        accessClock += 1
        index[key] = Entry(kind: entry.kind, bytes: entry.bytes, access: accessClock)
        return url
    }

    /// Re-hash the on-disk bytes and confirm they still match the locator checksum. A
    /// caller that detects a decode failure at use time can call this and `evict` on
    /// false (ADR-0010 §9) rather than serving corrupt media.
    public func verifyOnDisk(_ locator: MediaLocator) -> Bool {
        guard let data = try? Data(contentsOf: fileURL(for: locator.objectKey)) else { return false }
        return locator.checksum.validates(data, using: hasher)
    }

    // MARK: - Presentation guard & eviction

    public func beginPresenting(_ locator: MediaLocator) { presented.insert(locator.objectKey) }
    public func endPresenting(_ locator: MediaLocator) { presented.remove(locator.objectKey) }

    public func evict(_ locator: MediaLocator) { remove(key: locator.objectKey) }

    // MARK: - Introspection (tests / diagnostics; non-sensitive)

    public var cachedByteCount: Int { totalBytes }
    public func isCached(_ locator: MediaLocator) -> Bool { index[locator.objectKey] != nil }
    public var cachedObjectKeys: Set<String> { Set(index.keys) }

    // MARK: - Internals

    private func remove(key: String) {
        guard let entry = index[key] else { return }
        try? fileManager.removeItem(at: fileURL(for: key))
        index[key] = nil
        totalBytes -= entry.bytes
    }

    /// Deterministic eviction: evictable = not presented; order = videos before posters
    /// (posters survive longer), then least-recently-used first. `access` is globally
    /// unique so the ordering is total and reproducible.
    private func enforceBudget() {
        guard totalBytes > limits.maxBytes else { return }
        let candidates = index
            .filter { !presented.contains($0.key) }
            .sorted { lhs, rhs in
                let lRank = lhs.value.kind == .video ? 0 : 1
                let rRank = rhs.value.kind == .video ? 0 : 1
                if lRank != rRank { return lRank < rRank }
                return lhs.value.access < rhs.value.access
            }
        for (key, _) in candidates {
            if totalBytes <= limits.maxBytes { break }
            remove(key: key)
        }
    }

    private func fileURL(for objectKey: String) -> URL {
        directory.appendingPathComponent(Self.filename(forObjectKey: objectKey))
    }

    /// Keep the on-disk listing deterministic regardless of FileManager ordering.
    private static func sortedByName(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    // Object keys use only `[a-z0-9-/.]` (slugs never contain `_`), so `/`↔`_` is a
    // safe, reversible flattening to a single cache directory.
    static func filename(forObjectKey key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
    }

    static func objectKey(fromFilename name: String) -> String {
        name.replacingOccurrences(of: "_", with: "/")
    }

    static func kind(forObjectKey key: String) -> MediaKind? {
        if key.contains("/poster-") { return .poster }
        if key.contains("/video-") { return .video }
        return nil
    }
}
