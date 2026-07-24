import Foundation
import MazidiFoundations

// ─────────────────────────────────────────────────────────────────────────────
//  Media manifest read model (ADR-0011 §3/§6). The delivery projection of the
//  catalogue (slug → poster/video refs, retired entries already removed). Loaded the
//  same safe way as the catalogue; exposes locators for the fetch/cache layer.
// ─────────────────────────────────────────────────────────────────────────────

/// Safe loader for the committed `media-manifest.json`, mirroring the catalogue loader:
/// missing resource / corrupt bytes / unsupported schema each become a typed safe state.
public enum MediaManifestLoader {
    public static let supportedSchemaVersion = ExerciseCatalogue.currentSchemaVersion

    public static func load(from data: Data) -> Result<MediaManifest, CatalogueLoadError> {
        let manifest: MediaManifest
        do {
            manifest = try CatalogueSerialization.decode(MediaManifest.self, from: data)
        } catch {
            return .failure(.unreadable)
        }
        guard manifest.schemaVersion == supportedSchemaVersion else {
            return .failure(.unsupportedSchema(found: manifest.schemaVersion, supported: supportedSchemaVersion))
        }
        return .success(manifest)
    }

    public static func load(contentsOf url: URL?) -> Result<MediaManifest, CatalogueLoadError> {
        guard let url, let data = try? Data(contentsOf: url) else { return .failure(.resourceMissing) }
        return load(from: data)
    }
}

/// In-memory manifest store: slug → media refs, and slug+kind → `MediaLocator` for the
/// fetch/cache layer. Immutable after init.
public struct MediaManifestStore: Sendable {
    public let manifest: MediaManifest
    private let bySlug: [ExerciseSlug: MediaManifest.Record]

    public init(manifest: MediaManifest) {
        self.manifest = manifest
        var index: [ExerciseSlug: MediaManifest.Record] = [:]
        for record in manifest.records where index[record.slug] == nil {
            index[record.slug] = record
        }
        self.bySlug = index
    }

    public func record(for slug: ExerciseSlug) -> MediaManifest.Record? { bySlug[slug] }

    public func ref(for slug: ExerciseSlug, kind: MediaKind) -> MediaAssetRef? {
        guard let record = bySlug[slug] else { return nil }
        switch kind {
        case .poster: return record.poster
        case .video: return record.video
        }
    }

    /// The addressing unit (id + checksum) for a slug's poster/video, or nil when the
    /// manifest has no such asset (e.g. a `posterOnly` entry has no video locator).
    public func locator(for slug: ExerciseSlug, kind: MediaKind) -> MediaLocator? {
        guard let ref = ref(for: slug, kind: kind) else { return nil }
        return MediaLocator(slug: slug, ref: ref)
    }
}
