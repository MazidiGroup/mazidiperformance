import Foundation
import MazidiFoundations
import Testing
@testable import MazidiContent

@Suite struct SlugFormatTests {
    @Test func canonicalSlugsAreAccepted() {
        for slug in ["barbell-squat", "abdominals-stretch-variation-4", "wall-sit", "x", "a1-b2"] {
            #expect(ExerciseSlug.isCanonicalFormat(slug), "\(slug) should be canonical")
        }
    }

    @Test func nonCanonicalSlugsAreRejected() {
        for slug in ["", "Barbell-Squat", "barbell squat", "-leading", "trailing-", "double--hyphen", "unicode-café", "under_score"] {
            #expect(!ExerciseSlug.isCanonicalFormat(slug), "\(slug) should be rejected")
        }
    }
}

@Suite struct MappingClassifierTests {
    private func inventory(
        slugs: [String],
        posters: [String]? = nil,
        videos: [String]? = nil
    ) -> SourceInventory {
        SourceInventory(
            metadata: slugs.map { SourceMetadataRecord(slug: $0, name: $0) },
            posterFiles: posters ?? slugs.map { "posters/\($0).webp" },
            videoFiles: videos ?? slugs.map { "\($0).mp4" }
        )
    }

    @Test func perfectLibraryClassifiesAllExact() {
        let result = MappingClassifier.classify(inventory: inventory(slugs: ["barbell-squat", "wall-sit"]))
        #expect(result.records.count == 2)
        #expect(result.records.allSatisfy { $0.confidence == .exact })
        #expect(result.report.exactCount == 4)  // 2 posters + 2 videos
        #expect(!result.report.requiresHumanAttention)
    }

    @Test func caseDifferenceClassifiesAsNormalisedNotExact() {
        let result = MappingClassifier.classify(inventory: inventory(
            slugs: ["barbell-squat"],
            posters: ["posters/Barbell-Squat.webp"]
        ))
        #expect(result.records.count == 1)
        #expect(result.records[0].confidence == .normalised)
        #expect(result.records[0].posterFile == "posters/Barbell-Squat.webp")
        #expect(result.report.normalised.count == 1)
        #expect(!result.report.requiresHumanAttention)  // included, noted, no human gate
    }

    @Test func collidingFilesAreAmbiguousAndExcluded() {
        let result = MappingClassifier.classify(inventory: inventory(
            slugs: ["barbell-squat"],
            posters: ["posters/barbell-squat.webp", "posters/Barbell-Squat.webp"]
        ))
        // Both candidates reported; no poster resolved → record excluded later.
        #expect(result.report.ambiguous.count == 2)
        #expect(result.records[0].posterFile == nil)
        #expect(result.report.recordFindings.contains { $0.slug == "barbell-squat" && $0.excluded })
        #expect(result.report.requiresHumanAttention)
    }

    @Test func fileWithoutMetadataRecordIsUnmatched() {
        let result = MappingClassifier.classify(inventory: inventory(
            slugs: ["barbell-squat"],
            videos: ["barbell-squat.mp4", "mystery-movement.mp4"]
        ))
        #expect(result.report.unmatchedFiles.count == 1)
        #expect(result.report.unmatchedFiles[0].file == "mystery-movement.mp4")
        #expect(result.report.requiresHumanAttention)
    }

    @Test func wrongExtensionIsUnmatchedNeverCoerced() {
        let result = MappingClassifier.classify(inventory: inventory(
            slugs: ["barbell-squat"],
            videos: ["barbell-squat.mp4", "barbell-squat.avi"]
        ))
        #expect(result.report.unmatchedFiles.contains { $0.file == "barbell-squat.avi" })
        // The proper .mp4 still resolves.
        #expect(result.records[0].videoFile == "barbell-squat.mp4")
    }

    @Test func missingVideoYieldsPosterOnlyFindingNotExclusion() {
        let result = MappingClassifier.classify(inventory: inventory(
            slugs: ["barbell-squat"],
            videos: []
        ))
        #expect(result.records[0].posterFile != nil)
        #expect(result.records[0].videoFile == nil)
        let finding = result.report.recordFindings.first { $0.slug == "barbell-squat" }
        #expect(finding != nil && finding?.excluded == false)
    }

    @Test func missingPosterExcludesTheRecord() {
        let result = MappingClassifier.classify(inventory: inventory(
            slugs: ["barbell-squat"],
            posters: []
        ))
        #expect(result.report.recordFindings.contains { $0.slug == "barbell-squat" && $0.excluded })
        #expect(result.report.requiresHumanAttention)
    }

    @Test func duplicateMetadataSlugExcludesEveryCopy() {
        // Two metadata records claim the same slug — unresolvable, never deduped.
        let inventory = SourceInventory(
            metadata: [
                SourceMetadataRecord(slug: "barbell-squat", name: "Barbell Squat"),
                SourceMetadataRecord(slug: "barbell-squat", name: "Back Squat"),
                SourceMetadataRecord(slug: "wall-sit", name: "Wall Sit"),
            ],
            posterFiles: ["posters/barbell-squat.webp", "posters/wall-sit.webp"],
            videoFiles: ["barbell-squat.mp4", "wall-sit.mp4"]
        )
        let result = MappingClassifier.classify(inventory: inventory)
        #expect(result.records.map(\.record.slug) == ["wall-sit"])  // only the unique slug survives
        #expect(result.report.recordFindings.contains { $0.slug == "barbell-squat" && $0.excluded && $0.reason.contains("duplicate") })
        #expect(result.report.requiresHumanAttention)
    }

    @Test func nonCanonicalMetadataSlugIsExcluded() {
        let result = MappingClassifier.classify(inventory: inventory(slugs: ["Bad Slug!", "wall-sit"]))
        #expect(result.records.map(\.record.slug) == ["wall-sit"])
        #expect(result.report.recordFindings.contains { $0.slug == "Bad Slug!" && $0.excluded })
    }

    @Test func trackedOverrideResolvesAFileByHumanDecision() {
        let overrides = MappingOverrides(overrides: [
            .init(file: "posters/squat_final_v2.webp", slug: "barbell-squat", kind: .poster)
        ])
        let result = MappingClassifier.classify(
            inventory: inventory(slugs: ["barbell-squat"], posters: ["posters/squat_final_v2.webp"]),
            overrides: overrides
        )
        #expect(result.records[0].posterFile == "posters/squat_final_v2.webp")
        // Override use is recorded, not silent.
        #expect(result.report.normalised.contains { $0.file == "posters/squat_final_v2.webp" })
        #expect(!result.report.requiresHumanAttention)
    }

    @Test func directoryEntriesInListingsAreIgnored() {
        let result = MappingClassifier.classify(inventory: inventory(
            slugs: ["wall-sit"],
            posters: ["posters/", "posters/wall-sit.webp"]
        ))
        #expect(result.records[0].posterFile == "posters/wall-sit.webp")
        #expect(result.report.unmatchedFiles.isEmpty)
    }
}
