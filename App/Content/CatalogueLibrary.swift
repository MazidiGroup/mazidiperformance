import Foundation
import MazidiContent
import MazidiDomain
import MazidiFoundations

/// Loads the bundled canonical catalogue + delivery manifest once and vends the app-facing
/// read models and the composed media resolver (ADR-0011 §1/§4). Loading is SAFE: a missing
/// or unsupported-schema resource degrades to an empty catalogue/manifest — media falls back
/// to the bundled tier and search returns nothing — never a launch crash.
struct CatalogueLibrary: Sendable {
    let catalogue: ExerciseCatalogue
    let manifestStore: MediaManifestStore

    init(bundle: Bundle = .main) {
        switch ExerciseCatalogueLoader.load(contentsOf: bundle.url(forResource: "catalogue", withExtension: "json")) {
        case let .success(loaded): catalogue = loaded
        case .failure: catalogue = Self.empty
        }
        switch MediaManifestLoader.load(contentsOf: bundle.url(forResource: "media-manifest", withExtension: "json")) {
        case let .success(loaded): manifestStore = MediaManifestStore(manifest: loaded)
        case .failure: manifestStore = MediaManifestStore(manifest: MediaManifest(catalogue: Self.empty))
        }
    }

    private static let empty = ExerciseCatalogue(catalogueVersion: 0, sourceFingerprint: [:], records: [])

    /// The composed media resolver: validated cache → bundled representative → (async remote
    /// when an origin is configured; inert today). `cacheDirectory` nil disables the cache
    /// tier. `mediaBaseURL` comes from the active `.xcconfig` via Info.plist (empty → no
    /// remote origin), so no CDN host is ever hard-coded.
    func mediaResolver(
        cacheDirectory: URL? = try? MediaCache.deviceGlobalDirectory(),
        mediaBaseURL: String? = Bundle.main.object(forInfoDictionaryKey: "MediaBaseURL") as? String
    ) -> AppCatalogueMediaResolver {
        let reader = cacheDirectory.map { MediaCacheReader(directory: $0, hasher: CryptoKitMediaHasher()) }
        return AppCatalogueMediaResolver(core: CatalogueMediaResolver(
            manifest: manifestStore,
            cacheReader: reader,
            bundled: AppBundleMediaLocator(),
            remoteOrigin: RemoteMediaOrigin(configuredBaseURL: mediaBaseURL)
        ))
    }

    /// A catalogue query store joined to a naming source (client-content) for search.
    func catalogueStore(naming: any ExerciseNaming) -> ExerciseCatalogueStore {
        ExerciseCatalogueStore(catalogue: catalogue, naming: naming, legacy: .current)
    }
}

/// Adapts the Foundation-only `CatalogueMediaResolver` to the app's synchronous
/// `MediaResolving` seam (drop-in for `BundleMediaResolver`). The composed resolver rejects
/// any corrupt/checksum-mismatched cache entry before returning a URL (ADR-0011 §4/§5).
struct AppCatalogueMediaResolver: MediaResolving {
    let core: CatalogueMediaResolver
    func posterURL(for slug: ExerciseSlug) -> URL? { core.posterURL(for: slug) }
    func clipURL(for slug: ExerciseSlug) -> URL? { core.clipURL(for: slug) }
}

/// Client-content provider over the bundled full draft (all catalogued slugs). Serves both
/// as `ExerciseContentProviding` (coach preview copy) and `ExerciseNaming` (catalogue
/// search by display name + approved aliases). All copy is DRAFT (contentStatus
/// draft_requires_human_review) and is labelled "DRAFT COPY · PENDING REVIEW" wherever shown.
struct CatalogueContentProvider: ExerciseContentProviding, ExerciseNaming {
    private let bySlug: [ExerciseSlug: ExerciseContent]

    init(bundle: Bundle = .main) {
        guard
            let url = bundle.url(forResource: "mazidi-client-content-draft", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([ExerciseContent].self, from: data)
        else {
            bySlug = [:]
            return
        }
        bySlug = Dictionary(decoded.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func content(for slug: ExerciseSlug) -> ExerciseContent? { bySlug[slug] }

    func naming(for slug: ExerciseSlug) -> ExerciseNames? {
        guard let content = bySlug[slug] else { return nil }
        return ExerciseNames(displayName: content.displayName, aliases: content.aliases)
    }
}
