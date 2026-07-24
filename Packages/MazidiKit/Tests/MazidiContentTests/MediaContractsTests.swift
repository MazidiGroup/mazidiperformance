import Foundation
import MazidiFoundations
import Testing
@testable import MazidiContent

@Suite struct MediaContractsTests {
    // Deterministic fake hasher: identity-ish, maps known bytes to a controllable hex.
    private struct FakeHasher: MediaChecksumHashing {
        let table: [Data: String]
        func sha256Hex(_ data: Data) -> String { table[data] ?? "unknown" }
    }

    private let squat: ExerciseSlug = "barbell-squat"

    private func ref(_ kind: MediaKind, version: Int = 1, sha: String = "abc", bytes: Int = 10) -> MediaAssetRef {
        MediaAssetRef(kind: kind, contentVersion: version, sha256: sha, bytes: bytes, slug: squat)
    }

    // MARK: - Locator / object keys

    @Test func locatorObjectKeyIsProviderNeutralRelative() {
        let locator = MediaLocator(slug: squat, ref: ref(.poster, version: 2))
        #expect(locator.objectKey == "exercises/barbell-squat/poster-v2.webp")
        #expect(locator.id.kind == .poster)
        #expect(locator.checksum.bytes == 10)
    }

    @Test func differentContentVersionsAreDifferentKeys() {
        let v1 = MediaLocator(slug: squat, ref: ref(.video, version: 1))
        let v2 = MediaLocator(slug: squat, ref: ref(.video, version: 2))
        #expect(v1.objectKey != v2.objectKey)   // version-pinned keys — CG5 cache separation
        #expect(v1 != v2)
    }

    // MARK: - Checksum validation

    @Test func checksumValidatesOnMatchingSizeAndHash() {
        let data = Data("poster-bytes".utf8)
        let hasher = FakeHasher(table: [data: "deadbeef"])
        let checksum = MediaChecksum(sha256: "DEADBEEF", bytes: data.count)  // case-insensitive
        #expect(checksum.validates(data, using: hasher))
    }

    @Test func checksumFailsOnHashMismatch() {
        let data = Data("poster-bytes".utf8)
        let hasher = FakeHasher(table: [data: "0000"])
        let checksum = MediaChecksum(sha256: "deadbeef", bytes: data.count)
        #expect(!checksum.validates(data, using: hasher))
    }

    @Test func checksumFailsOnSizeMismatchEvenIfHashTableWouldMatch() {
        let data = Data("short".utf8)
        let hasher = FakeHasher(table: [data: "deadbeef"])
        let checksum = MediaChecksum(sha256: "deadbeef", bytes: data.count + 1)  // wrong size
        #expect(!checksum.validates(data, using: hasher))
    }

    // MARK: - Remote origin (injected MEDIA_BASE_URL)

    @Test func remoteOriginNilForEmptyOrMissingConfig() {
        #expect(RemoteMediaOrigin(configuredBaseURL: nil) == nil)
        #expect(RemoteMediaOrigin(configuredBaseURL: "") == nil)
        #expect(RemoteMediaOrigin(configuredBaseURL: "   ") == nil)
        #expect(RemoteMediaOrigin(configuredBaseURL: "exercises/only/a/path") == nil)  // no scheme
    }

    @Test func remoteOriginJoinsBaseURLWithObjectKey() throws {
        let origin = try #require(RemoteMediaOrigin(configuredBaseURL: "https://cdn.example/media"))
        let locator = MediaLocator(slug: squat, ref: ref(.poster))
        #expect(origin.url(for: locator).absoluteString == "https://cdn.example/media/exercises/barbell-squat/poster-v1.webp")
    }

    // MARK: - Manifest lookup

    @Test func manifestStoreResolvesRecordsAndLocators() {
        let catalogue = ExerciseCatalogue(
            catalogueVersion: 1, sourceFingerprint: [:],
            records: [
                CatalogueRecord(slug: squat, primaryMuscles: [], secondaryMuscles: [], equipment: [],
                                movementPattern: [], difficulty: "beginner", tags: [], durationMs: nil,
                                poster: ref(.poster), video: ref(.video),
                                availabilityStatus: .available, contentReviewStatus: .pendingReview),
                CatalogueRecord(slug: "wall-sit", primaryMuscles: [], secondaryMuscles: [], equipment: [],
                                movementPattern: [], difficulty: "beginner", tags: [], durationMs: nil,
                                poster: MediaAssetRef(kind: .poster, contentVersion: 1, sha256: "z", bytes: 3, slug: "wall-sit"),
                                video: nil, availabilityStatus: .posterOnly, contentReviewStatus: .pendingReview),
            ]
        )
        let store = MediaManifestStore(manifest: MediaManifest(catalogue: catalogue))
        #expect(store.locator(for: squat, kind: .poster)?.objectKey == "exercises/barbell-squat/poster-v1.webp")
        #expect(store.locator(for: squat, kind: .video)?.objectKey == "exercises/barbell-squat/video-v1.mp4")
        #expect(store.locator(for: "wall-sit", kind: .video) == nil)   // poster-only: no video locator
        #expect(store.locator(for: "nope", kind: .poster) == nil)       // unknown slug
    }

    // MARK: - Manifest loader safe states

    @Test func manifestLoaderReturnsTypedSafeStates() {
        #expect({ if case .failure(.resourceMissing) = MediaManifestLoader.load(contentsOf: nil) { true } else { false } }())
        #expect({ if case .failure(.unreadable) = MediaManifestLoader.load(from: Data("x".utf8)) { true } else { false } }())
    }
}
