import Foundation
import CryptoKit
import MazidiContent
import MazidiFoundations

/// Real SHA-256 hasher backing the media checksum guarantee end-to-end (ADR-0011 §6).
/// MazidiContent stays Foundation-only and injects this seam; the app supplies CryptoKit
/// (an accepted Apple-framework use, as in MazidiAuth's path hashing). Downloaded/cached
/// bytes are validated against the manifest's REAL SHA-256 before ever being presented.
struct CryptoKitMediaHasher: MediaChecksumHashing {
    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Locates the approved bundled representative media set (2 clips + 8 posters) — the same
/// bundle probing the previous `BundleMediaResolver` used, now behind the composed
/// resolver's tier 2 (ADR-0011 §4). Missing media returns nil so the view falls back.
struct AppBundleMediaLocator: BundledMediaLocating {
    func bundledURL(for slug: ExerciseSlug, kind: MediaKind) -> URL? {
        switch kind {
        case .poster:
            return Bundle.main.url(forResource: slug.rawValue, withExtension: "webp", subdirectory: "Media/posters")
                ?? Bundle.main.url(forResource: slug.rawValue, withExtension: "webp")
        case .video:
            return Bundle.main.url(forResource: slug.rawValue, withExtension: "mp4", subdirectory: "Media/clips")
                ?? Bundle.main.url(forResource: slug.rawValue, withExtension: "mp4")
        }
    }
}
