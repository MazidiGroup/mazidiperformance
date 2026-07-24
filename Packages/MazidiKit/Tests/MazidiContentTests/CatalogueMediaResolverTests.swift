import Foundation
import MazidiFoundations
import Testing
@testable import MazidiContent

@Suite struct CatalogueMediaResolverTests {
    private struct FNVHasher: MediaChecksumHashing {
        func sha256Hex(_ data: Data) -> String {
            var h: UInt64 = 1469598103934665603
            for byte in data { h = (h ^ UInt64(byte)) &* 1099511628211 }
            return String(h, radix: 16)
        }
    }

    private struct FakeBundle: BundledMediaLocating {
        let urls: [String: URL]   // "slug|kind" → bundled URL
        func bundledURL(for slug: ExerciseSlug, kind: MediaKind) -> URL? { urls["\(slug.rawValue)|\(kind.rawValue)"] }
    }

    private let hasher = FNVHasher()
    private let squat: ExerciseSlug = "barbell-squat"

    private func manifestStore(poster: MediaAssetRef?, video: MediaAssetRef?) -> MediaManifestStore {
        let catalogue = ExerciseCatalogue(
            catalogueVersion: 1, sourceFingerprint: [:],
            records: [CatalogueRecord(
                slug: squat, primaryMuscles: [], secondaryMuscles: [], equipment: [],
                movementPattern: [], difficulty: "beginner", tags: [], durationMs: nil,
                poster: poster, video: video,
                availabilityStatus: video == nil ? .posterOnly : .available,
                contentReviewStatus: .pendingReview
            )]
        )
        return MediaManifestStore(manifest: MediaManifest(catalogue: catalogue))
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write bytes into a cache dir under the object-key-derived filename.
    private func writeCache(_ dir: URL, objectKey: String, data: Data) throws {
        try data.write(to: dir.appendingPathComponent(MediaCache.filename(forObjectKey: objectKey)))
    }

    private func posterRef(_ data: Data, version: Int = 1) -> MediaAssetRef {
        MediaAssetRef(kind: .poster, contentVersion: version, sha256: hasher.sha256Hex(data), bytes: data.count, slug: squat)
    }

    // MARK: - Fallback order

    @Test func bundledUsedWhenNoCache() throws {
        let bundledURL = URL(fileURLWithPath: "/bundle/barbell-squat.webp")
        let resolver = CatalogueMediaResolver(
            manifest: manifestStore(poster: posterRef(Data("x".utf8)), video: nil),
            cacheReader: nil,
            bundled: FakeBundle(urls: ["barbell-squat|poster": bundledURL])
        )
        #expect(resolver.posterURL(for: squat) == bundledURL)   // tier 2
    }

    @Test func validatedCacheWinsOverBundled() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data("cached-poster".utf8)
        let ref = posterRef(data)
        try writeCache(dir, objectKey: ref.objectKey, data: data)
        let resolver = CatalogueMediaResolver(
            manifest: manifestStore(poster: ref, video: nil),
            cacheReader: MediaCacheReader(directory: dir, hasher: hasher),
            bundled: FakeBundle(urls: ["barbell-squat|poster": URL(fileURLWithPath: "/bundle/barbell-squat.webp")])
        )
        let url = try #require(resolver.posterURL(for: squat))
        #expect(url.lastPathComponent == MediaCache.filename(forObjectKey: ref.objectKey))   // tier 1, not bundle
    }

    @Test func offlineValidatedCacheIsUsableWithoutNetwork() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data("offline".utf8)
        let ref = posterRef(data)
        try writeCache(dir, objectKey: ref.objectKey, data: data)
        let resolver = CatalogueMediaResolver(
            manifest: manifestStore(poster: ref, video: nil),
            cacheReader: MediaCacheReader(directory: dir, hasher: hasher),
            bundled: FakeBundle(urls: [:]),                 // nothing bundled
            remoteOrigin: nil                                // no network
        )
        #expect(resolver.posterURL(for: squat) != nil)      // served purely from cache
    }

    @Test func missingEverywhereResolvesToNil() {
        let resolver = CatalogueMediaResolver(
            manifest: manifestStore(poster: posterRef(Data("x".utf8)), video: nil),
            cacheReader: nil,
            bundled: FakeBundle(urls: [:])
        )
        #expect(resolver.posterURL(for: squat) == nil)      // → view shows name+icon
        #expect(resolver.clipURL(for: squat) == nil)         // poster-only: no video
    }

    // MARK: - Corruption safety (presentation path)

    @Test func sameSizeCorruptedCacheEntryIsNeverPresentedAndFallsBackToBundle() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let good = Data("abcd".utf8)
        let ref = posterRef(good)
        // Write a DIFFERENT payload of the SAME byte length under the cache key.
        try writeCache(dir, objectKey: ref.objectKey, data: Data("wxyz".utf8))
        let bundledURL = URL(fileURLWithPath: "/bundle/barbell-squat.webp")
        let resolver = CatalogueMediaResolver(
            manifest: manifestStore(poster: ref, video: nil),
            cacheReader: MediaCacheReader(directory: dir, hasher: hasher),
            bundled: FakeBundle(urls: ["barbell-squat|poster": bundledURL])
        )
        // The presentation path (posterURL) must reject the corrupt cache file and serve
        // the approved bundled asset instead — never the tampered bytes.
        #expect(resolver.posterURL(for: squat) == bundledURL)
    }

    @Test func corruptCacheWithNoBundleResolvesToNilNotCorruptBytes() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ref = posterRef(Data("abcd".utf8))
        try writeCache(dir, objectKey: ref.objectKey, data: Data("wxyz".utf8))   // same-size tamper
        let resolver = CatalogueMediaResolver(
            manifest: manifestStore(poster: ref, video: nil),
            cacheReader: MediaCacheReader(directory: dir, hasher: hasher),
            bundled: FakeBundle(urls: [:])
        )
        #expect(resolver.posterURL(for: squat) == nil)      // corrupt entry never served
    }

    // MARK: - Remote tier (inert without origin)

    @Test func remoteURLNilWithoutOrigin() {
        let resolver = CatalogueMediaResolver(
            manifest: manifestStore(poster: posterRef(Data("x".utf8)), video: nil),
            cacheReader: nil,
            bundled: FakeBundle(urls: [:]),
            remoteOrigin: nil
        )
        #expect(resolver.remoteURL(for: squat, kind: .poster) == nil)   // honestly inert
    }

    @Test func remoteURLJoinsWhenOriginConfigured() throws {
        let ref = posterRef(Data("x".utf8))
        let resolver = CatalogueMediaResolver(
            manifest: manifestStore(poster: ref, video: nil),
            cacheReader: nil,
            bundled: FakeBundle(urls: [:]),
            remoteOrigin: RemoteMediaOrigin(configuredBaseURL: "https://cdn.example")
        )
        #expect(resolver.remoteURL(for: squat, kind: .poster)?.absoluteString
                == "https://cdn.example/\(ref.objectKey)")
    }
}
