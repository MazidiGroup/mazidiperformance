import Foundation
import MazidiFoundations
import Testing
@testable import MazidiContent

@Suite struct CatalogueLoadTests {
    // ExerciseCatalogue is not Equatable, so compare on the typed failure directly.
    private func failure(_ result: Result<ExerciseCatalogue, CatalogueLoadError>) -> CatalogueLoadError? {
        if case let .failure(error) = result { return error }
        return nil
    }

    private func catalogue(schemaVersion: Int) -> ExerciseCatalogue {
        let slug: ExerciseSlug = "barbell-squat"
        return ExerciseCatalogue(
            schemaVersion: schemaVersion,
            catalogueVersion: 1,
            sourceFingerprint: ["metadata.zip": "aa"],
            records: [CatalogueRecord(
                slug: slug, primaryMuscles: ["Quads"], secondaryMuscles: [], equipment: ["Barbell"],
                movementPattern: ["Squat"], difficulty: "intermediate", tags: ["strength"], durationMs: 9600,
                poster: MediaAssetRef(kind: .poster, contentVersion: 1, sha256: "ab", bytes: 10, slug: slug),
                video: MediaAssetRef(kind: .video, contentVersion: 1, sha256: "cd", bytes: 20, slug: slug),
                availabilityStatus: .available, contentReviewStatus: .pendingReview
            )]
        )
    }

    // Supported catalogue
    @Test func loadSupportedSchemaSucceeds() throws {
        let data = try CatalogueSerialization.encode(catalogue(schemaVersion: 1))
        let result = ExerciseCatalogueLoader.load(from: data)
        let loaded = try #require(try result.get())
        #expect(loaded.records.count == 1)
        #expect(loaded.schemaVersion == ExerciseCatalogueLoader.supportedSchemaVersion)
    }

    // Unsupported (future) schema → explicit safe state, never a crash
    @Test func loadUnsupportedSchemaReturnsTypedSafeState() throws {
        let data = try CatalogueSerialization.encode(catalogue(schemaVersion: 999))
        let result = ExerciseCatalogueLoader.load(from: data)
        #expect(failure(result) == .unsupportedSchema(found: 999, supported: 1))
    }

    // Corrupt/unreadable bytes → safe state
    @Test func loadCorruptDataReturnsUnreadable() {
        let result = ExerciseCatalogueLoader.load(from: Data("not json".utf8))
        #expect(failure(result) == .unreadable)
    }

    // Missing resource (nil URL) → safe state, no force-unwrap crash
    @Test func loadMissingResourceReturnsResourceMissing() {
        let result = ExerciseCatalogueLoader.load(contentsOf: nil)
        #expect(failure(result) == .resourceMissing)
    }

    // Missing resource (bad URL) → safe state
    @Test func loadNonexistentFileReturnsResourceMissing() {
        let url = URL(fileURLWithPath: "/definitely/not/here/catalogue.json")
        let result = ExerciseCatalogueLoader.load(contentsOf: url)
        #expect(failure(result) == .resourceMissing)
    }

    // Round-trips a real file on disk (isolated temp dir; nothing committed)
    @Test func loadContentsOfDecodesAValidFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("catalogue.json")
        try CatalogueSerialization.encode(catalogue(schemaVersion: 1)).write(to: url)
        let loaded = try ExerciseCatalogueLoader.load(contentsOf: url).get()
        #expect(loaded.record(for: "barbell-squat") != nil)
    }
}
