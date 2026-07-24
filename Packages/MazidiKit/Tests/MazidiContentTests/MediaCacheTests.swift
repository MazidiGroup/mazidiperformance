import Foundation
import MazidiFoundations
import Testing
@testable import MazidiContent

@Suite struct MediaCacheTests {
    // Deterministic, non-crypto content hash (FNV-1a) — reproducible run to run, so the
    // package tests never depend on CryptoKit or the network.
    private struct FNVHasher: MediaChecksumHashing {
        func sha256Hex(_ data: Data) -> String {
            var h: UInt64 = 1469598103934665603
            for byte in data { h = (h ^ UInt64(byte)) &* 1099511628211 }
            return String(h, radix: 16)
        }
    }

    private let hasher = FNVHasher()
    private let squat: ExerciseSlug = "barbell-squat"

    /// A locator whose checksum matches `data` under the fake hasher (a valid pairing).
    private func validLocator(_ data: Data, slug: ExerciseSlug = "barbell-squat", kind: MediaKind = .poster, version: Int = 1) -> MediaLocator {
        MediaLocator(
            id: MediaAssetID(slug: slug, kind: kind, contentVersion: version),
            checksum: MediaChecksum(sha256: hasher.sha256Hex(data), bytes: data.count)
        )
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeCache(_ dir: URL, maxBytes: Int = 512 * 1024 * 1024) throws -> MediaCache {
        try MediaCache(directory: dir, hasher: hasher, limits: .init(maxBytes: maxBytes))
    }

    // MARK: - Defaults

    @Test func defaultBudgetIs512MB() {
        #expect(MediaCache.Limits().maxBytes == 512 * 1024 * 1024)
    }

    // MARK: - Admission: valid hit + atomic promotion

    @Test func validBytesAdmittedAndReadableWithNoTempLeft() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try makeCache(dir)
        let data = Data("poster-bytes".utf8)
        let loc = validLocator(data)

        let url = try #require(await cache.admit(loc, data: data))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await cache.cachedURL(for: loc) == url)              // valid hit
        // Atomic promotion: exactly one file, no leftover ".dl-" temp.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files == [MediaCache.filename(forObjectKey: loc.objectKey)])
        #expect(!files.contains { $0.hasPrefix(".dl-") })
    }

    // MARK: - Admission: rejection paths

    @Test func checksumMismatchIsRejected() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try makeCache(dir)
        let data = Data("poster-bytes".utf8)
        // Wrong hash for these bytes.
        let bad = MediaLocator(id: MediaAssetID(slug: squat, kind: .poster, contentVersion: 1),
                               checksum: MediaChecksum(sha256: "not-the-hash", bytes: data.count))
        #expect(await cache.admit(bad, data: data) == nil)
        #expect(await cache.isCached(bad) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func sizeMismatchIsRejected() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try makeCache(dir)
        let data = Data("poster-bytes".utf8)
        let bad = MediaLocator(id: MediaAssetID(slug: squat, kind: .poster, contentVersion: 1),
                               checksum: MediaChecksum(sha256: hasher.sha256Hex(data), bytes: data.count + 1))
        #expect(await cache.admit(bad, data: data) == nil)
    }

    // MARK: - Interrupted download cleanup

    @Test func interruptedDownloadTempFilesRemovedOnInit() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Simulate a crashed download leaving a temp file.
        let leftover = dir.appendingPathComponent(".dl-abc123")
        try Data("partial".utf8).write(to: leftover)
        _ = try makeCache(dir)   // init cleans it
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    // MARK: - Corrupt-on-disk detection

    @Test func onDiskCorruptionIsRejectedOnRead() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try makeCache(dir)
        let data = Data("valid-poster".utf8)
        let loc = validLocator(data)
        _ = await cache.admit(loc, data: data)
        // Corrupt on disk with different-sized bytes.
        try Data("x".utf8).write(to: dir.appendingPathComponent(MediaCache.filename(forObjectKey: loc.objectKey)))
        #expect(await cache.cachedURL(for: loc) == nil)   // size check rejects it
    }

    @Test func verifyOnDiskCatchesEqualSizeCorruption() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try makeCache(dir)
        let data = Data("abcd".utf8)
        let loc = validLocator(data)
        _ = await cache.admit(loc, data: data)
        #expect(await cache.verifyOnDisk(loc))
        // Overwrite with same-size but different bytes.
        try Data("wxyz".utf8).write(to: dir.appendingPathComponent(MediaCache.filename(forObjectKey: loc.objectKey)))
        #expect(await cache.verifyOnDisk(loc) == false)   // re-hash catches it
    }

    // MARK: - Version separation (cache keys)

    @Test func differentContentVersionsAreSeparateCacheEntries() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try makeCache(dir)
        let d1 = Data("v1".utf8); let d2 = Data("v2-longer".utf8)
        let v1 = validLocator(d1, kind: .poster, version: 1)
        let v2 = validLocator(d2, kind: .poster, version: 2)
        _ = await cache.admit(v1, data: d1)
        _ = await cache.admit(v2, data: d2)
        #expect(await cache.isCached(v1))
        #expect(await cache.isCached(v2))
        await cache.evict(v1)
        #expect(await cache.isCached(v1) == false)
        #expect(await cache.isCached(v2))              // v2 unaffected by evicting v1
    }

    // MARK: - Eviction policy

    @Test func evictionRemovesVideosBeforePosters() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let posterData = Data(repeating: 0xA, count: 100)
        let videoData = Data(repeating: 0xB, count: 100)
        let cache = try makeCache(dir, maxBytes: 150)   // holds one 100-byte asset comfortably
        let poster = validLocator(posterData, kind: .poster, version: 1)
        let video = validLocator(videoData, slug: "wall-sit", kind: .video, version: 1)
        _ = await cache.admit(poster, data: posterData)
        _ = await cache.admit(video, data: videoData)   // total 200 > 150 → evict a video first
        #expect(await cache.isCached(poster))            // poster survives
        #expect(await cache.isCached(video) == false)    // video evicted
    }

    @Test func evictionIsLRUWithinSameKind() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = Data(repeating: 1, count: 100)
        let b = Data(repeating: 2, count: 100)
        let c = Data(repeating: 3, count: 100)
        let cache = try makeCache(dir, maxBytes: 250)
        let la = validLocator(a, slug: "ex-a", kind: .video, version: 1)
        let lb = validLocator(b, slug: "ex-b", kind: .video, version: 1)
        let lc = validLocator(c, slug: "ex-c", kind: .video, version: 1)
        _ = await cache.admit(la, data: a)
        _ = await cache.admit(lb, data: b)
        _ = await cache.cachedURL(for: la)               // bump A → B becomes least-recent
        _ = await cache.admit(lc, data: c)               // total 300 > 250 → evict least-recent (B)
        #expect(await cache.isCached(la))                // A survived (recently used)
        #expect(await cache.isCached(lb) == false)       // B evicted
        #expect(await cache.isCached(lc))
    }

    @Test func presentedFileIsNeverEvicted() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let v1 = Data(repeating: 1, count: 100)
        let v2 = Data(repeating: 2, count: 100)
        let cache = try makeCache(dir, maxBytes: 150)
        let l1 = validLocator(v1, slug: "ex-1", kind: .video, version: 1)
        let l2 = validLocator(v2, slug: "ex-2", kind: .video, version: 1)
        _ = await cache.admit(l1, data: v1)
        await cache.beginPresenting(l1)                  // pin the older one
        _ = await cache.admit(l2, data: v2)              // 200 > 150 → must evict l2, not l1
        #expect(await cache.isCached(l1))                // presented file kept despite being older
        #expect(await cache.isCached(l2) == false)
    }

    // MARK: - Offline reuse across reopen

    @Test func cachedMediaSurvivesReopenForOfflineUse() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data("persist".utf8)
        let loc = validLocator(data)
        let first = try makeCache(dir)
        _ = await first.admit(loc, data: data)
        // New cache instance over the same directory (simulates relaunch) — no network.
        let reopened = try makeCache(dir)
        #expect(await reopened.isCached(loc))
        #expect(await reopened.cachedURL(for: loc) != nil)
        #expect(await reopened.cachedByteCount == data.count)
    }

    // MARK: - Path privacy

    @Test func cachePathsContainNoAccountIdOnlyObjectKeyParts() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try makeCache(dir)
        let data = Data("p".utf8)
        let loc = validLocator(data)
        let url = try #require(await cache.admit(loc, data: data))
        let name = url.lastPathComponent
        #expect(name.contains("barbell-squat"))            // slug (non-private) present
        #expect(name.contains("poster"))                   // media type present
        #expect(name.contains("v1"))                       // version present
        #expect(!name.lowercased().contains("account"))    // no account scoping in the path
    }

    @Test func deviceGlobalDirectoryIsUnderCachesAndNotAccountScoped() throws {
        let dir = try MediaCache.deviceGlobalDirectory()
        let path = dir.path
        #expect(path.contains("Caches"))
        #expect(path.hasSuffix("MazidiPerformance/exercise-media"))
        #expect(!path.contains("accounts"))                // device-global, never per-account
    }

    // MARK: - Graceful failure

    @Test func admitReturnsNilWithoutThrowingWhenDirectoryIsGone() async throws {
        let dir = try tempDir()
        let cache = try makeCache(dir)
        try FileManager.default.removeItem(at: dir)         // yank the directory
        let data = Data("bytes".utf8)
        #expect(await cache.admit(validLocator(data), data: data) == nil)   // no throw, just nil
    }
}
