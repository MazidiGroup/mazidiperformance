import Foundation
import MazidiFoundations

// ─────────────────────────────────────────────────────────────────────────────
//  Catalogue construction (ADR-0010 §2, §3, §8, §9, §12).
//  Pure function of (classification, digests, previous catalogue, fingerprint):
//  media versions are pinned by checksum, catalogueVersion bumps only on real
//  change, and slugs absent from the source are retired — never deleted.
// ─────────────────────────────────────────────────────────────────────────────

public struct CatalogueBuildResult: Sendable {
    public let catalogue: ExerciseCatalogue
    public let manifest: MediaManifest
    public let report: ReviewReport
}

public enum CatalogueBuildError: Error, Equatable {
    /// A resolved source file has no digest — the audit pass is incomplete.
    case missingDigest(file: String)
}

public enum CatalogueBuilder {
    public static func build(
        classification: MappingClassification,
        digests: [String: AssetDigest],
        previous: ExerciseCatalogue?,
        sourceFingerprint: [String: String]
    ) throws -> CatalogueBuildResult {
        var recordFindings = classification.report.recordFindings
        var records: [CatalogueRecord] = []

        for classified in classification.records {
            let slug = ExerciseSlug(classified.record.slug)
            let previousRecord = previous?.record(for: slug)

            func ref(for file: String?, kind: MediaKind) throws -> MediaAssetRef? {
                guard let file else { return nil }
                guard let digest = digests[file] else { throw CatalogueBuildError.missingDigest(file: file) }
                guard digest.bytes > 0 else {
                    // Malformed (§9): excluded from the manifest, reported.
                    recordFindings.append(.init(
                        slug: slug.rawValue,
                        reason: "\(kind.rawValue) file is zero bytes — excluded as malformed",
                        excluded: true
                    ))
                    return nil
                }
                // Immutable versioning (§2): same checksum keeps its version;
                // changed bytes mint the next version; new assets start at 1.
                let previousRef = kind == .poster ? previousRecord?.poster : previousRecord?.video
                let version: Int
                if let previousRef {
                    version = previousRef.sha256 == digest.sha256 ? previousRef.contentVersion : previousRef.contentVersion + 1
                } else {
                    version = 1
                }
                return MediaAssetRef(kind: kind, contentVersion: version, sha256: digest.sha256, bytes: digest.bytes, slug: slug)
            }

            let poster = try ref(for: classified.posterFile, kind: .poster)
            let video = try ref(for: classified.videoFile, kind: .video)
            guard poster != nil else { continue }  // poster mandatory (§7); finding already recorded

            records.append(CatalogueRecord(
                slug: slug,
                primaryMuscles: classified.record.primaryMuscles,
                secondaryMuscles: classified.record.secondaryMuscles,
                equipment: classified.record.equipment,
                movementPattern: classified.record.movementPattern,
                difficulty: classified.record.difficulty,
                tags: classified.record.tags,
                durationMs: classified.record.durationSeconds.map { Int(($0 * 1000).rounded()) },
                poster: poster,
                video: video,
                availabilityStatus: video == nil ? .posterOnly : .available,
                contentReviewStatus: .pendingReview
            ))
        }

        // Retirement (§12): previously catalogued slugs missing from the source
        // keep their last known record, marked retired — historical assignments
        // must always resolve to something.
        if let previous {
            let currentSlugs = Set(records.map(\.slug))
            for old in previous.records where !currentSlugs.contains(old.slug) {
                records.append(CatalogueRecord(
                    slug: old.slug,
                    primaryMuscles: old.primaryMuscles,
                    secondaryMuscles: old.secondaryMuscles,
                    equipment: old.equipment,
                    movementPattern: old.movementPattern,
                    difficulty: old.difficulty,
                    tags: old.tags,
                    durationMs: old.durationMs,
                    poster: old.poster,
                    video: old.video,
                    availabilityStatus: .retired,
                    contentReviewStatus: old.contentReviewStatus
                ))
                if old.availabilityStatus != .retired {
                    recordFindings.append(.init(
                        slug: old.slug.rawValue,
                        reason: "absent from source library — retired, retained for historical references",
                        excluded: false
                    ))
                }
            }
        }

        // Version bump only on real change (§3).
        let sortedRecords = records.sorted { $0.slug.rawValue < $1.slug.rawValue }
        let catalogueVersion: Int
        if let previous, previous.records == sortedRecords, previous.sourceFingerprint == sourceFingerprint {
            catalogueVersion = previous.catalogueVersion
        } else {
            catalogueVersion = (previous?.catalogueVersion ?? 0) + 1
        }

        let catalogue = ExerciseCatalogue(
            catalogueVersion: catalogueVersion,
            sourceFingerprint: sourceFingerprint,
            records: sortedRecords
        )
        return CatalogueBuildResult(
            catalogue: catalogue,
            manifest: MediaManifest(catalogue: catalogue),
            report: ReviewReport(
                exactCount: classification.report.exactCount,
                normalised: classification.report.normalised,
                ambiguous: classification.report.ambiguous,
                unmatchedFiles: classification.report.unmatchedFiles,
                recordFindings: recordFindings.sorted { ($0.slug, $0.reason) < ($1.slug, $1.reason) }
            )
        )
    }
}
