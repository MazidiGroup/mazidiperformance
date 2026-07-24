import Foundation
import MazidiFoundations

// ─────────────────────────────────────────────────────────────────────────────
//  Source-library inputs (ADR-0010 §4). These types describe what the audit
//  tool *found* — file listings and technical metadata — never where it found
//  them: no absolute paths survive into any generated artifact.
// ─────────────────────────────────────────────────────────────────────────────

/// One record of the source library's `metadata.json`. Only the technical
/// fields the catalogue needs are decoded; marketing/instructional copy is
/// deliberately ignored here (client copy is the client-content layer's job).
public struct SourceMetadataRecord: Codable, Hashable, Sendable {
    public let slug: String
    public let name: String
    public let primaryMuscles: [String]
    public let secondaryMuscles: [String]
    public let equipment: [String]
    public let movementPattern: [String]
    public let difficulty: String
    public let durationSeconds: Double?
    public let tags: [String]
    public let posterFile: String?
    public let videoFile: String?

    public init(
        slug: String,
        name: String,
        primaryMuscles: [String] = [],
        secondaryMuscles: [String] = [],
        equipment: [String] = [],
        movementPattern: [String] = [],
        difficulty: String = "beginner",
        durationSeconds: Double? = nil,
        tags: [String] = [],
        posterFile: String? = nil,
        videoFile: String? = nil
    ) {
        self.slug = slug
        self.name = name
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.movementPattern = movementPattern
        self.difficulty = difficulty
        self.durationSeconds = durationSeconds
        self.tags = tags
        self.posterFile = posterFile
        self.videoFile = videoFile
    }
}

/// Everything the read-only audit pass extracted: metadata records plus the
/// poster/video file listings (zip entry names, directory prefixes included).
public struct SourceInventory: Sendable {
    public let metadata: [SourceMetadataRecord]
    public let posterFiles: [String]
    public let videoFiles: [String]

    public init(metadata: [SourceMetadataRecord], posterFiles: [String], videoFiles: [String]) {
        self.metadata = metadata
        // Directory entries (trailing slash) are listing artifacts, not assets.
        self.posterFiles = posterFiles.filter { !$0.hasSuffix("/") }
        self.videoFiles = videoFiles.filter { !$0.hasSuffix("/") }
    }
}

/// SHA-256 + size for one source file, keyed by its listing name.
public struct AssetDigest: Hashable, Sendable {
    public let sha256: String
    public let bytes: Int

    public init(sha256: String, bytes: Int) {
        self.sha256 = sha256
        self.bytes = bytes
    }
}

/// Tracked human resolutions for ambiguous/unmatched files
/// (`content/exercises/catalogue/mapping-overrides.json`, ADR-0010 §10).
/// The tool never guesses; every entry here is an explicit decision.
public struct MappingOverrides: Codable, Sendable {
    public struct Override: Codable, Hashable, Sendable {
        /// Source listing name being resolved (e.g. `posters/foo (1).webp`).
        public let file: String
        public let slug: String
        public let kind: MediaKind

        public init(file: String, slug: String, kind: MediaKind) {
            self.file = file
            self.slug = slug
            self.kind = kind
        }
    }

    public let schemaVersion: Int
    public let overrides: [Override]

    public init(schemaVersion: Int = 1, overrides: [Override] = []) {
        self.schemaVersion = schemaVersion
        self.overrides = overrides
    }

    public static let empty = MappingOverrides()
}
