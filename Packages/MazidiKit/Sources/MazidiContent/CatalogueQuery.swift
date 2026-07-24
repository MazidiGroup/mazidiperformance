import Foundation
import MazidiFoundations

// ─────────────────────────────────────────────────────────────────────────────
//  App-facing catalogue read model / query boundary (ADR-0011 §1).
//  Foundation-only, immutable after load, no source-relative paths exposed. Client
//  copy (display names + aliases) is NOT in the catalogue — it is joined by slug via
//  an injected `ExerciseNaming` source (the client-content layer), preserving the
//  ADR-0010 §1/§3 rule that the catalogue never carries client copy.
// ─────────────────────────────────────────────────────────────────────────────

/// Client-facing naming for a slug, joined from the client-content layer. The catalogue
/// itself never stores these.
public struct ExerciseNames: Sendable, Equatable {
    public let displayName: String
    public let aliases: [String]

    public init(displayName: String, aliases: [String] = []) {
        self.displayName = displayName
        self.aliases = aliases
    }
}

/// Injected join from slug → client-facing names (display name + approved aliases).
public protocol ExerciseNaming: Sendable {
    func naming(for slug: ExerciseSlug) -> ExerciseNames?
}

/// A naming source with no entries — every record sorts and matches by its slug only.
/// The safe default until the client-content join is wired (CG6/CG7).
public struct EmptyExerciseNaming: ExerciseNaming {
    public init() {}
    public func naming(for _: ExerciseSlug) -> ExerciseNames? { nil }
}

/// Deterministic map of historical fixture slugs that are **not** themselves canonical
/// catalogue ids → their canonical id (ADR-0011 §2). **Empty today**: every bundled
/// fixture slug is already a direct canonical id (integration review §5). The code path
/// is retained so a future non-canonical id resolves deterministically — never guessed.
public struct LegacyFixtureSlugMap: Sendable, Equatable {
    private let map: [ExerciseSlug: ExerciseSlug]

    public init(_ map: [ExerciseSlug: ExerciseSlug] = [:]) { self.map = map }

    /// The canonical map shipped today: empty (identity resolution for all fixtures).
    public static let current = LegacyFixtureSlugMap()

    /// The canonical slug a legacy id maps to, or nil when there is no explicit entry.
    public func canonicalSlug(for slug: ExerciseSlug) -> ExerciseSlug? { map[slug] }

    public var isEmpty: Bool { map.isEmpty }
}

/// Deterministic, validated filter over the catalogue's real classification dimensions
/// (ADR-0011 §1). Each axis is an OR-set; axes AND together; an empty axis is "no
/// constraint". Matching is case-insensitive. An unknown value simply matches nothing
/// (deterministic empty), so callers can pass user selections safely.
///
/// NOTE: "prescription mode" (reps/timed/distance/effort) is deliberately **not** a
/// filter axis here — it is a domain/coach concept (`Prescription`), not a property the
/// source library or catalogue carries. Filtering exercises by prescription suitability
/// belongs to the Coach layer (CG7) joining catalogue results with domain logic, and is
/// not fabricated onto catalogue records.
public struct CatalogueFilter: Sendable, Equatable {
    public var equipment: Set<String>
    public var movementPatterns: Set<String>
    public var primaryMuscles: Set<String>
    public var difficulties: Set<String>
    /// Retired exercises are excluded from results by default (not pickable); opt in for
    /// historical/administrative views.
    public var includeRetired: Bool

    public init(
        equipment: Set<String> = [],
        movementPatterns: Set<String> = [],
        primaryMuscles: Set<String> = [],
        difficulties: Set<String> = [],
        includeRetired: Bool = false
    ) {
        self.equipment = equipment
        self.movementPatterns = movementPatterns
        self.primaryMuscles = primaryMuscles
        self.difficulties = difficulties
        self.includeRetired = includeRetired
    }

    public var hasClassificationConstraint: Bool {
        !(equipment.isEmpty && movementPatterns.isEmpty && primaryMuscles.isEmpty && difficulties.isEmpty)
    }
}

/// The read/query boundary the Coach picker/search and Client resolution consume.
/// Read-only; conforming types are immutable after construction.
public protocol ExerciseCatalogueReading: Sendable {
    /// All records, in the catalogue's canonical slug-sorted order (deterministic).
    var allRecords: [CatalogueRecord] { get }
    /// Canonical lookup by exact slug.
    func record(for slug: ExerciseSlug) -> CatalogueRecord?
    /// Resolution path (ADR-0011 §2): canonical id → known-fixture-slug map → nil.
    /// Returns nil for an unknown id; the caller preserves the frozen label / shows the
    /// media-unavailable state rather than guessing.
    func resolve(_ slug: ExerciseSlug) -> CatalogueRecord?
    /// Case/diacritic-insensitive search over names + aliases (+ slug), filtered and
    /// stably ordered.
    func search(_ text: String?, filter: CatalogueFilter) -> [CatalogueRecord]
    /// Sorted, de-duplicated filter vocabularies (validated pick lists for the UI).
    var availableEquipment: [String] { get }
    var availableMovementPatterns: [String] { get }
    var availablePrimaryMuscles: [String] { get }
    var availableDifficulties: [String] { get }
}

public extension ExerciseCatalogueReading {
    func search(_ text: String? = nil) -> [CatalogueRecord] { search(text, filter: CatalogueFilter()) }
}

/// In-memory catalogue store built from a loaded `ExerciseCatalogue`. Immutable after
/// init; the slug index is computed once. Holds no file URLs — callers never see a
/// source-relative path (media object keys are provider-neutral relative keys, ADR-0010
/// §6, not filesystem paths).
public struct ExerciseCatalogueStore: ExerciseCatalogueReading {
    public let catalogue: ExerciseCatalogue
    private let naming: any ExerciseNaming
    private let legacy: LegacyFixtureSlugMap
    private let bySlug: [ExerciseSlug: CatalogueRecord]

    public init(
        catalogue: ExerciseCatalogue,
        naming: any ExerciseNaming = EmptyExerciseNaming(),
        legacy: LegacyFixtureSlugMap = .current
    ) {
        self.catalogue = catalogue
        self.naming = naming
        self.legacy = legacy
        // First-wins on any accidental duplicate slug (records are slug-sorted) — never
        // trap, so a hand-edited catalogue can't crash the app.
        var index: [ExerciseSlug: CatalogueRecord] = [:]
        for record in catalogue.records where index[record.slug] == nil {
            index[record.slug] = record
        }
        self.bySlug = index
    }

    public var allRecords: [CatalogueRecord] { catalogue.records }

    public func record(for slug: ExerciseSlug) -> CatalogueRecord? { bySlug[slug] }

    public func resolve(_ slug: ExerciseSlug) -> CatalogueRecord? {
        if let direct = bySlug[slug] { return direct }
        if let canonical = legacy.canonicalSlug(for: slug), let mapped = bySlug[canonical] { return mapped }
        return nil
    }

    public func search(_ text: String?, filter: CatalogueFilter = CatalogueFilter()) -> [CatalogueRecord] {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = (trimmed?.isEmpty == false) ? Self.fold(trimmed!) : nil

        let matched = catalogue.records.filter { record in
            guard filter.includeRetired || record.availabilityStatus != .retired else { return false }
            guard Self.matches(record, filter) else { return false }
            guard let needle else { return true }
            return Self.matchesText(record, needle: needle, naming: naming)
        }
        return matched.sorted { lhs, rhs in
            let lk = Self.sortKey(lhs, naming: naming)
            let rk = Self.sortKey(rhs, naming: naming)
            if lk != rk { return lk < rk }
            return lhs.slug.rawValue < rhs.slug.rawValue  // stable, globally-unique tiebreak
        }
    }

    public var availableEquipment: [String] { vocab(\.equipment) }
    public var availableMovementPatterns: [String] { vocab(\.movementPattern) }
    public var availablePrimaryMuscles: [String] { vocab(\.primaryMuscles) }
    public var availableDifficulties: [String] {
        Array(Set(pickable.map(\.difficulty))).sorted()
    }

    // MARK: - Internals

    /// Records eligible to appear in the UI (retired excluded) — drives search default
    /// and the filter vocabularies.
    private var pickable: [CatalogueRecord] {
        catalogue.records.filter { $0.availabilityStatus != .retired }
    }

    private func vocab(_ key: KeyPath<CatalogueRecord, [String]>) -> [String] {
        Array(Set(pickable.flatMap { $0[keyPath: key] })).sorted()
    }

    /// Locale-independent case + diacritic folding for deterministic matching/ordering.
    static func fold(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private static func sortKey(_ record: CatalogueRecord, naming: any ExerciseNaming) -> String {
        fold(naming.naming(for: record.slug)?.displayName ?? record.slug.rawValue)
    }

    private static func matchesText(_ record: CatalogueRecord, needle: String, naming: any ExerciseNaming) -> Bool {
        if fold(record.slug.rawValue).contains(needle) { return true }
        guard let names = naming.naming(for: record.slug) else { return false }
        if fold(names.displayName).contains(needle) { return true }
        return names.aliases.contains { fold($0).contains(needle) }
    }

    private static func matches(_ record: CatalogueRecord, _ filter: CatalogueFilter) -> Bool {
        func axis(_ selected: Set<String>, _ values: [String]) -> Bool {
            if selected.isEmpty { return true }
            let lowered = Set(values.map { $0.lowercased() })
            return selected.contains { lowered.contains($0.lowercased()) }
        }
        return axis(filter.equipment, record.equipment)
            && axis(filter.movementPatterns, record.movementPattern)
            && axis(filter.primaryMuscles, record.primaryMuscles)
            && axis(filter.difficulties, [record.difficulty])
    }
}
