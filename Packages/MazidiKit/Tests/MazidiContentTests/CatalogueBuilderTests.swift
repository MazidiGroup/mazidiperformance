import Foundation
import MazidiFoundations
import Testing
@testable import MazidiContent

@Suite struct CatalogueBuilderTests {
    private let fingerprint = ["metadata.zip": "aa", "posters.zip": "bb", "videos.zip": "cc"]

    private func classified(_ slugs: [String]) -> MappingClassification {
        MappingClassifier.classify(inventory: SourceInventory(
            metadata: slugs.map { SourceMetadataRecord(slug: $0, name: $0, durationSeconds: 9.6) },
            posterFiles: slugs.map { "posters/\($0).webp" },
            videoFiles: slugs.map { "\($0).mp4" }
        ))
    }

    private func digests(_ slugs: [String], posterSHA: (String) -> String = { "p-\($0)" }, videoSHA: (String) -> String = { "v-\($0)" }) -> [String: AssetDigest] {
        var digests: [String: AssetDigest] = [:]
        for slug in slugs {
            digests["posters/\(slug).webp"] = AssetDigest(sha256: posterSHA(slug), bytes: 100)
            digests["\(slug).mp4"] = AssetDigest(sha256: videoSHA(slug), bytes: 2000)
        }
        return digests
    }

    @Test func firstBuildStartsAtVersionOneEverywhere() throws {
        let result = try CatalogueBuilder.build(
            classification: classified(["barbell-squat", "wall-sit"]),
            digests: digests(["barbell-squat", "wall-sit"]),
            previous: nil,
            sourceFingerprint: fingerprint
        )
        #expect(result.catalogue.catalogueVersion == 1)
        #expect(result.catalogue.records.count == 2)
        for record in result.catalogue.records {
            #expect(record.availabilityStatus == .available)
            #expect(record.contentReviewStatus == .pendingReview)
            #expect(record.poster?.contentVersion == 1)
            #expect(record.video?.contentVersion == 1)
            #expect(record.durationMs == 9600)
        }
        // Slug-sorted, deterministic.
        #expect(result.catalogue.records.map(\.slug.rawValue) == ["barbell-squat", "wall-sit"])
    }

    @Test func objectKeysAreProviderNeutralRelativePaths() throws {
        let result = try CatalogueBuilder.build(
            classification: classified(["barbell-squat"]),
            digests: digests(["barbell-squat"]),
            previous: nil,
            sourceFingerprint: fingerprint
        )
        let record = try #require(result.catalogue.record(for: "barbell-squat"))
        #expect(record.poster?.objectKey == "exercises/barbell-squat/poster-v1.webp")
        #expect(record.video?.objectKey == "exercises/barbell-squat/video-v1.mp4")
    }

    @Test func unchangedInputKeepsCatalogueVersionAndAssetVersions() throws {
        let first = try CatalogueBuilder.build(
            classification: classified(["barbell-squat"]),
            digests: digests(["barbell-squat"]),
            previous: nil,
            sourceFingerprint: fingerprint
        )
        let second = try CatalogueBuilder.build(
            classification: classified(["barbell-squat"]),
            digests: digests(["barbell-squat"]),
            previous: first.catalogue,
            sourceFingerprint: fingerprint
        )
        #expect(second.catalogue.catalogueVersion == 1)
        #expect(second.catalogue.records == first.catalogue.records)
    }

    @Test func changedBytesMintTheNextContentVersion() throws {
        let first = try CatalogueBuilder.build(
            classification: classified(["barbell-squat"]),
            digests: digests(["barbell-squat"]),
            previous: nil,
            sourceFingerprint: fingerprint
        )
        let second = try CatalogueBuilder.build(
            classification: classified(["barbell-squat"]),
            digests: digests(["barbell-squat"], videoSHA: { "re-encoded-\($0)" }),
            previous: first.catalogue,
            sourceFingerprint: ["metadata.zip": "aa", "posters.zip": "bb", "videos.zip": "dd"]
        )
        let record = try #require(second.catalogue.record(for: "barbell-squat"))
        #expect(second.catalogue.catalogueVersion == 2)
        #expect(record.video?.contentVersion == 2)
        #expect(record.video?.objectKey == "exercises/barbell-squat/video-v2.mp4")
        // Poster bytes unchanged → version and key stay put (§7 independence).
        #expect(record.poster?.contentVersion == 1)
    }

    @Test func slugAbsentFromSourceIsRetiredNeverDeleted() throws {
        let first = try CatalogueBuilder.build(
            classification: classified(["barbell-squat", "wall-sit"]),
            digests: digests(["barbell-squat", "wall-sit"]),
            previous: nil,
            sourceFingerprint: fingerprint
        )
        let second = try CatalogueBuilder.build(
            classification: classified(["barbell-squat"]),
            digests: digests(["barbell-squat"]),
            previous: first.catalogue,
            sourceFingerprint: ["metadata.zip": "aa2", "posters.zip": "bb2", "videos.zip": "cc2"]
        )
        let retired = try #require(second.catalogue.record(for: "wall-sit"))
        #expect(retired.availabilityStatus == .retired)
        #expect(retired.poster != nil)  // historical references still resolve
        #expect(second.manifest.records.map(\.slug.rawValue) == ["barbell-squat"])  // delivery manifest excludes retired
        #expect(second.report.recordFindings.contains { $0.slug == "wall-sit" && !$0.excluded })
    }

    @Test func zeroByteVideoIsMalformedAndYieldsPosterOnly() throws {
        var badDigests = digests(["barbell-squat"])
        badDigests["barbell-squat.mp4"] = AssetDigest(sha256: "whatever", bytes: 0)
        let result = try CatalogueBuilder.build(
            classification: classified(["barbell-squat"]),
            digests: badDigests,
            previous: nil,
            sourceFingerprint: fingerprint
        )
        let record = try #require(result.catalogue.record(for: "barbell-squat"))
        #expect(record.availabilityStatus == .posterOnly)
        #expect(record.video == nil)
        #expect(result.report.recordFindings.contains { $0.reason.contains("zero bytes") })
        #expect(result.report.requiresHumanAttention)
    }

    @Test func zeroBytePosterExcludesTheRecord() throws {
        var badDigests = digests(["barbell-squat"])
        badDigests["posters/barbell-squat.webp"] = AssetDigest(sha256: "whatever", bytes: 0)
        let result = try CatalogueBuilder.build(
            classification: classified(["barbell-squat"]),
            digests: badDigests,
            previous: nil,
            sourceFingerprint: fingerprint
        )
        #expect(result.catalogue.records.isEmpty)
        #expect(result.report.requiresHumanAttention)
    }

    @Test func missingDigestIsAHardErrorNotASilentSkip() {
        #expect(throws: CatalogueBuildError.missingDigest(file: "posters/barbell-squat.webp")) {
            _ = try CatalogueBuilder.build(
                classification: classified(["barbell-squat"]),
                digests: [:],
                previous: nil,
                sourceFingerprint: fingerprint
            )
        }
    }
}

@Suite struct CatalogueSerializationTests {
    @Test func encodingIsByteDeterministic() throws {
        let build = { () -> ExerciseCatalogue in
            let slug: ExerciseSlug = "barbell-squat"
            let record = CatalogueRecord(
                slug: slug,
                primaryMuscles: ["Quads"], secondaryMuscles: [], equipment: ["Barbell"],
                movementPattern: ["Squat"], difficulty: "intermediate", tags: ["strength"],
                durationMs: 9600,
                poster: MediaAssetRef(kind: .poster, contentVersion: 1, sha256: "ab", bytes: 10, slug: slug),
                video: MediaAssetRef(kind: .video, contentVersion: 1, sha256: "cd", bytes: 20, slug: slug),
                availabilityStatus: .available,
                contentReviewStatus: .pendingReview
            )
            return ExerciseCatalogue(catalogueVersion: 1, sourceFingerprint: ["a.zip": "ff"], records: [record])
        }
        let first = try CatalogueSerialization.encode(build())
        let second = try CatalogueSerialization.encode(build())
        #expect(first == second)
        let text = try #require(String(data: first, encoding: .utf8))
        #expect(text.hasSuffix("\n"))
        #expect(!text.contains("\\/"))  // withoutEscapingSlashes: object keys stay readable
    }

    @Test func catalogueRoundTripsThroughItsSerialization() throws {
        let slug: ExerciseSlug = "wall-sit"
        let catalogue = ExerciseCatalogue(
            catalogueVersion: 3,
            sourceFingerprint: ["videos.zip": "0abc"],
            records: [CatalogueRecord(
                slug: slug, primaryMuscles: ["Quads"], secondaryMuscles: ["Core"],
                equipment: ["Bodyweight"], movementPattern: ["Isometric"], difficulty: "beginner",
                tags: [], durationMs: nil,
                poster: MediaAssetRef(kind: .poster, contentVersion: 2, sha256: "ee", bytes: 5, slug: slug),
                video: nil,
                availabilityStatus: .posterOnly,
                contentReviewStatus: .pendingReview
            )]
        )
        let decoded = try CatalogueSerialization.decode(ExerciseCatalogue.self, from: CatalogueSerialization.encode(catalogue))
        #expect(decoded.catalogueVersion == 3)
        #expect(decoded.records == catalogue.records)
        #expect(decoded.record(for: slug)?.poster?.objectKey == "exercises/wall-sit/poster-v2.webp")
    }

    @Test func manifestDerivesFromCatalogueAndOmitsRetired() throws {
        let active: ExerciseSlug = "wall-sit"
        let gone: ExerciseSlug = "gone-move"
        let catalogue = ExerciseCatalogue(
            catalogueVersion: 2,
            sourceFingerprint: [:],
            records: [
                CatalogueRecord(slug: active, primaryMuscles: [], secondaryMuscles: [], equipment: [],
                                movementPattern: [], difficulty: "beginner", tags: [], durationMs: nil,
                                poster: MediaAssetRef(kind: .poster, contentVersion: 1, sha256: "aa", bytes: 1, slug: active),
                                video: nil, availabilityStatus: .posterOnly, contentReviewStatus: .pendingReview),
                CatalogueRecord(slug: gone, primaryMuscles: [], secondaryMuscles: [], equipment: [],
                                movementPattern: [], difficulty: "beginner", tags: [], durationMs: nil,
                                poster: MediaAssetRef(kind: .poster, contentVersion: 1, sha256: "bb", bytes: 1, slug: gone),
                                video: nil, availabilityStatus: .retired, contentReviewStatus: .pendingReview),
            ]
        )
        let manifest = MediaManifest(catalogue: catalogue)
        #expect(manifest.catalogueVersion == 2)
        #expect(manifest.records.map(\.slug) == [active])
    }
}
