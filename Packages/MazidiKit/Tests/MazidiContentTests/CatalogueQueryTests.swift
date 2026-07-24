import Foundation
import MazidiFoundations
import Testing
@testable import MazidiContent

@Suite struct CatalogueQueryTests {
    // A small fake naming source (stands in for the client-content join).
    private struct FakeNaming: ExerciseNaming {
        let entries: [ExerciseSlug: ExerciseNames]
        func naming(for slug: ExerciseSlug) -> ExerciseNames? { entries[slug] }
    }

    private func record(
        _ slug: ExerciseSlug,
        equipment: [String] = ["Barbell"],
        movement: [String] = ["Squat"],
        primary: [String] = ["Quads"],
        difficulty: String = "intermediate",
        availability: AvailabilityStatus = .available
    ) -> CatalogueRecord {
        CatalogueRecord(
            slug: slug, primaryMuscles: primary, secondaryMuscles: [], equipment: equipment,
            movementPattern: movement, difficulty: difficulty, tags: [], durationMs: 9600,
            poster: availability == .retired ? MediaAssetRef(kind: .poster, contentVersion: 1, sha256: "p", bytes: 1, slug: slug)
                                             : MediaAssetRef(kind: .poster, contentVersion: 1, sha256: "p", bytes: 1, slug: slug),
            video: availability == .posterOnly ? nil : MediaAssetRef(kind: .video, contentVersion: 1, sha256: "v", bytes: 2, slug: slug),
            availabilityStatus: availability, contentReviewStatus: .pendingReview
        )
    }

    private func catalogue(_ records: [CatalogueRecord]) -> ExerciseCatalogue {
        ExerciseCatalogue(catalogueVersion: 1, sourceFingerprint: [:], records: records)
    }

    private func store(_ records: [CatalogueRecord], naming: FakeNaming = FakeNaming(entries: [:]), legacy: LegacyFixtureSlugMap = .current) -> ExerciseCatalogueStore {
        ExerciseCatalogueStore(catalogue: catalogue(records), naming: naming, legacy: legacy)
    }

    // MARK: - Lookup: canonical / legacy / unknown

    @Test func canonicalLookupReturnsRecord() {
        let s = store([record("barbell-squat"), record("wall-sit")])
        #expect(s.record(for: "barbell-squat")?.slug == "barbell-squat")
        #expect(s.resolve("wall-sit")?.slug == "wall-sit")
    }

    @Test func unknownSlugResolvesToNil() {
        let s = store([record("barbell-squat")])
        #expect(s.record(for: "does-not-exist") == nil)
        #expect(s.resolve("does-not-exist") == nil)
    }

    @Test func legacySlugResolvesThroughExplicitMap() {
        // A non-canonical historical id explicitly mapped to a canonical id.
        let legacy = LegacyFixtureSlugMap(["old-back-squat": "barbell-squat"])
        let s = store([record("barbell-squat")], legacy: legacy)
        #expect(s.record(for: "old-back-squat") == nil)      // not a canonical id
        #expect(s.resolve("old-back-squat")?.slug == "barbell-squat")  // resolves via the map
    }

    @Test func shippedLegacyMapIsEmptyIdentityToday() {
        // Documents integration review §5: all fixture slugs are direct canonical ids.
        #expect(LegacyFixtureSlugMap.current.isEmpty)
    }

    // MARK: - Search: case / diacritic / alias / slug

    @Test func searchIsCaseAndDiacriticInsensitive() {
        let naming = FakeNaming(entries: ["cafe-curl": ExerciseNames(displayName: "Café Curl")])
        let s = store([record("cafe-curl")], naming: naming)
        #expect(s.search("cafe").map(\.slug) == ["cafe-curl"])   // no accent, lowercase
        #expect(s.search("CAFÉ").map(\.slug) == ["cafe-curl"])   // accent, uppercase
    }

    @Test func searchMatchesAliases() {
        let naming = FakeNaming(entries: ["barbell-squat": ExerciseNames(displayName: "Back Squat", aliases: ["High-Bar Squat"])])
        let s = store([record("barbell-squat")], naming: naming)
        #expect(s.search("high-bar").map(\.slug) == ["barbell-squat"])
    }

    @Test func searchFallsBackToSlugWhenNoNaming() {
        let s = store([record("barbell-squat")])  // empty naming
        #expect(s.search("squat").map(\.slug) == ["barbell-squat"])
    }

    @Test func noMatchReturnsEmpty() {
        let s = store([record("barbell-squat")])
        #expect(s.search("kayak").isEmpty)
    }

    @Test func emptyOrWhitespaceQueryReturnsAllPickable() {
        let s = store([record("barbell-squat"), record("wall-sit")])
        #expect(s.search(nil).count == 2)
        #expect(s.search("   ").count == 2)
    }

    // MARK: - Ordering

    @Test func searchResultsOrderedByDisplayName() {
        let naming = FakeNaming(entries: [
            "z-slug": ExerciseNames(displayName: "Apple Press"),
            "a-slug": ExerciseNames(displayName: "Zebra Row"),
        ])
        let s = store([record("z-slug"), record("a-slug")], naming: naming)
        // Ordered by name (Apple < Zebra), not by slug.
        #expect(s.search(nil).map(\.slug) == ["z-slug", "a-slug"])
    }

    @Test func orderingTieBreaksBySlugDeterministically() {
        let naming = FakeNaming(entries: [
            "slug-b": ExerciseNames(displayName: "Same Name"),
            "slug-a": ExerciseNames(displayName: "Same Name"),
        ])
        let s = store([record("slug-b"), record("slug-a")], naming: naming)
        #expect(s.search(nil).map(\.slug) == ["slug-a", "slug-b"])  // slug tiebreak
    }

    // MARK: - Filters

    @Test func filterByEquipment() {
        let s = store([
            record("barbell-squat", equipment: ["Barbell"]),
            record("kettlebell-swing", equipment: ["Kettlebell"], movement: ["Hinge"]),
        ])
        let out = s.search(nil, filter: CatalogueFilter(equipment: ["kettlebell"]))  // case-insensitive
        #expect(out.map(\.slug) == ["kettlebell-swing"])
    }

    @Test func filterByCategoryMovementPattern() {
        let s = store([
            record("barbell-squat", movement: ["Squat"]),
            record("deadlift", movement: ["Hinge"]),
        ])
        let out = s.search(nil, filter: CatalogueFilter(movementPatterns: ["Hinge"]))
        #expect(out.map(\.slug) == ["deadlift"])
    }

    @Test func combinedFiltersIntersect() {
        let s = store([
            record("a", equipment: ["Barbell"], movement: ["Squat"]),
            record("b", equipment: ["Barbell"], movement: ["Hinge"]),
            record("c", equipment: ["Kettlebell"], movement: ["Hinge"]),
        ])
        // Barbell AND Hinge → only b.
        let out = s.search(nil, filter: CatalogueFilter(equipment: ["Barbell"], movementPatterns: ["Hinge"]))
        #expect(out.map(\.slug) == ["b"])
    }

    @Test func unknownFilterValueMatchesNothingDeterministically() {
        let s = store([record("barbell-squat", equipment: ["Barbell"])])
        #expect(s.search(nil, filter: CatalogueFilter(equipment: ["Nonexistent"])).isEmpty)
    }

    // MARK: - Retirement & vocabularies

    @Test func retiredExcludedByDefaultButAvailableOnRequest() {
        let s = store([
            record("current", availability: .available),
            record("old", availability: .retired),
        ])
        #expect(s.search(nil).map(\.slug) == ["current"])
        #expect(Set(s.search(nil, filter: CatalogueFilter(includeRetired: true)).map(\.slug)) == ["current", "old"])
    }

    @Test func availableVocabulariesAreSortedDeduplicatedAndExcludeRetired() {
        let s = store([
            record("a", equipment: ["Barbell", "Rack"], movement: ["Squat"], difficulty: "intermediate"),
            record("b", equipment: ["Barbell"], movement: ["Hinge"], difficulty: "beginner"),
            record("old", equipment: ["Machine"], availability: .retired),
        ])
        #expect(s.availableEquipment == ["Barbell", "Rack"])         // "Machine" excluded (retired), deduped, sorted
        #expect(s.availableMovementPatterns == ["Hinge", "Squat"])
        #expect(s.availableDifficulties == ["beginner", "intermediate"])
    }

    // MARK: - Immutability / no source paths exposed

    @Test func exposedMediaKeysAreProviderNeutralRelativeNotSourcePaths() {
        let s = store([record("barbell-squat")])
        let rec = s.record(for: "barbell-squat")
        #expect(rec?.poster?.objectKey == "exercises/barbell-squat/poster-v1.webp")
        #expect(rec?.poster?.objectKey.hasPrefix("/") == false)  // never an absolute/source path
    }

    @Test func allRecordsPreserveCanonicalSlugSortedOrder() {
        let s = store([record("wall-sit"), record("barbell-squat")])
        #expect(s.allRecords.map(\.slug.rawValue) == ["barbell-squat", "wall-sit"])
    }
}
