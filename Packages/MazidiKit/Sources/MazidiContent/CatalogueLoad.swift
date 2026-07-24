import Foundation

// ─────────────────────────────────────────────────────────────────────────────
//  Safe catalogue loading (ADR-0011 §1). Loading a bundled catalogue must NEVER
//  crash launch: a missing resource, unreadable/corrupt bytes, or an unsupported
//  future schema each resolve to an explicit typed failure the caller handles by
//  degrading (empty catalogue → media-unavailable fallback), never by trapping.
// ─────────────────────────────────────────────────────────────────────────────

/// Why a catalogue could not be loaded. Exhaustive and `Equatable` so callers (and
/// tests) can branch on the exact safe state.
public enum CatalogueLoadError: Error, Equatable, Sendable {
    /// The resource URL was nil or its bytes could not be read (not bundled / no file).
    case resourceMissing
    /// Bytes were present but did not decode as an `ExerciseCatalogue`.
    case unreadable
    /// Decoded, but its `schemaVersion` is not one this build supports.
    case unsupportedSchema(found: Int, supported: Int)
}

/// Loads and schema-validates an `ExerciseCatalogue`. Pure/deterministic; performs no
/// I/O beyond the optional `Data(contentsOf:)` convenience.
public enum ExerciseCatalogueLoader {
    /// The single schema version this build understands (ADR-0010 §3).
    public static let supportedSchemaVersion = ExerciseCatalogue.currentSchemaVersion

    /// Decode + schema-gate from in-memory bytes. Never throws — returns a typed result.
    public static func load(from data: Data) -> Result<ExerciseCatalogue, CatalogueLoadError> {
        let catalogue: ExerciseCatalogue
        do {
            catalogue = try CatalogueSerialization.decode(ExerciseCatalogue.self, from: data)
        } catch {
            return .failure(.unreadable)
        }
        guard catalogue.schemaVersion == supportedSchemaVersion else {
            return .failure(.unsupportedSchema(found: catalogue.schemaVersion, supported: supportedSchemaVersion))
        }
        return .success(catalogue)
    }

    /// Convenience for bundled resources: `url` is the optional returned by
    /// `Bundle.url(forResource:…)`, so a not-bundled resource maps to `.resourceMissing`
    /// instead of a force-unwrap crash.
    public static func load(contentsOf url: URL?) -> Result<ExerciseCatalogue, CatalogueLoadError> {
        guard let url, let data = try? Data(contentsOf: url) else { return .failure(.resourceMissing) }
        return load(from: data)
    }
}
