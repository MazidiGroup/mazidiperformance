import Foundation
import MazidiFoundations

// ─────────────────────────────────────────────────────────────────────────────
//  Exercise catalogue & media manifest models (ADR-0010).
//  The committed catalogue.json / media-manifest.json are encoded from these
//  types deterministically (CatalogueSerialization): stable slug order, sorted
//  keys, no timestamps, no machine paths — same inputs, identical bytes.
// ─────────────────────────────────────────────────────────────────────────────

/// The two media kinds a catalogue entry can carry. Poster is mandatory for a
/// non-retired entry; video is optional (ADR-0010 §7).
public enum MediaKind: String, Codable, Hashable, Sendable, CaseIterable {
    case poster
    case video

    /// Canonical file extension for remote object keys and source matching.
    public var fileExtension: String {
        switch self {
        case .poster: "webp"
        case .video: "mp4"
        }
    }
}

/// Immutable media identity: `(slug, kind, contentVersion)` permanently bound to
/// one SHA-256 (ADR-0010 §2). Replacing bytes mints the next `contentVersion`;
/// an existing version's checksum never changes.
public struct MediaAssetRef: Codable, Hashable, Sendable {
    public let kind: MediaKind
    public let contentVersion: Int
    /// Lowercase hex SHA-256 of the asset bytes.
    public let sha256: String
    public let bytes: Int
    /// Provider-neutral relative key (ADR-0010 §6) — never a hostname, bucket,
    /// credential, or absolute path.
    public let objectKey: String

    public init(kind: MediaKind, contentVersion: Int, sha256: String, bytes: Int, slug: ExerciseSlug) {
        self.kind = kind
        self.contentVersion = contentVersion
        self.sha256 = sha256
        self.bytes = bytes
        self.objectKey = Self.objectKey(slug: slug, kind: kind, contentVersion: contentVersion)
    }

    public static func objectKey(slug: ExerciseSlug, kind: MediaKind, contentVersion: Int) -> String {
        "exercises/\(slug.rawValue)/\(kind.rawValue)-v\(contentVersion).\(kind.fileExtension)"
    }
}

/// Whether an entry's media can currently be delivered (ADR-0010 §3/§7).
public enum AvailabilityStatus: String, Codable, Hashable, Sendable {
    /// Poster and video both present.
    case available
    /// Poster present, video missing/excluded — a legal degraded state.
    case posterOnly
    /// Removed from the source library; entry retained so historical references
    /// keep resolving (ADR-0010 §12). Never deleted.
    case retired
}

/// Catalogue-level review state. Client-facing wording is governed separately by
/// the client-content layer; nothing here is presented as approved copy.
public enum CatalogueReviewStatus: String, Codable, Hashable, Sendable {
    case pendingReview
    case approved
}

/// One exercise in the canonical catalogue. Classification fields pass through
/// from source metadata; client copy (names, instructions, cues) deliberately
/// does NOT live here — it joins by slug from the client-content layer.
public struct CatalogueRecord: Codable, Hashable, Sendable {
    public let slug: ExerciseSlug
    public let primaryMuscles: [String]
    public let secondaryMuscles: [String]
    public let equipment: [String]
    public let movementPattern: [String]
    public let difficulty: String
    public let tags: [String]
    public let durationMs: Int?
    public let poster: MediaAssetRef?
    public let video: MediaAssetRef?
    public let availabilityStatus: AvailabilityStatus
    public let contentReviewStatus: CatalogueReviewStatus

    public init(
        slug: ExerciseSlug,
        primaryMuscles: [String],
        secondaryMuscles: [String],
        equipment: [String],
        movementPattern: [String],
        difficulty: String,
        tags: [String],
        durationMs: Int?,
        poster: MediaAssetRef?,
        video: MediaAssetRef?,
        availabilityStatus: AvailabilityStatus,
        contentReviewStatus: CatalogueReviewStatus
    ) {
        self.slug = slug
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.movementPattern = movementPattern
        self.difficulty = difficulty
        self.tags = tags
        self.durationMs = durationMs
        self.poster = poster
        self.video = video
        self.availabilityStatus = availabilityStatus
        self.contentReviewStatus = contentReviewStatus
    }
}

/// The committed catalogue envelope. `sourceFingerprint` (SHA-256 per source
/// archive) replaces any timestamp so regeneration is byte-reproducible.
public struct ExerciseCatalogue: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Monotonic; bumped only when records or fingerprint actually change.
    public let catalogueVersion: Int
    public let sourceFingerprint: [String: String]
    /// Always sorted by slug (enforced by the builder and serializer).
    public let records: [CatalogueRecord]

    public init(schemaVersion: Int = ExerciseCatalogue.currentSchemaVersion,
                catalogueVersion: Int,
                sourceFingerprint: [String: String],
                records: [CatalogueRecord]) {
        self.schemaVersion = schemaVersion
        self.catalogueVersion = catalogueVersion
        self.sourceFingerprint = sourceFingerprint
        self.records = records.sorted { $0.slug.rawValue < $1.slug.rawValue }
    }

    public func record(for slug: ExerciseSlug) -> CatalogueRecord? {
        records.first { $0.slug == slug }
    }
}

/// The delivery manifest: slug → media refs only (the handoff's versioned
/// manifest with content hashes). Derived from the catalogue, never authored.
public struct MediaManifest: Codable, Sendable {
    public struct Record: Codable, Hashable, Sendable {
        public let slug: ExerciseSlug
        public let poster: MediaAssetRef?
        public let video: MediaAssetRef?

        public init(slug: ExerciseSlug, poster: MediaAssetRef?, video: MediaAssetRef?) {
            self.slug = slug
            self.poster = poster
            self.video = video
        }
    }

    public let schemaVersion: Int
    public let catalogueVersion: Int
    public let sourceFingerprint: [String: String]
    public let records: [Record]

    public init(catalogue: ExerciseCatalogue) {
        self.schemaVersion = catalogue.schemaVersion
        self.catalogueVersion = catalogue.catalogueVersion
        self.sourceFingerprint = catalogue.sourceFingerprint
        self.records = catalogue.records
            .filter { $0.availabilityStatus != .retired }
            .map { Record(slug: $0.slug, poster: $0.poster, video: $0.video) }
    }
}
