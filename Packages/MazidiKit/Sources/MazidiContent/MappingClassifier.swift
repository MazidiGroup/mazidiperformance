import Foundation
import MazidiFoundations

// ─────────────────────────────────────────────────────────────────────────────
//  Mapping classification (ADR-0010 §4, §7, §10).
//  Deterministic, side-effect free: source inventory in → classified records +
//  review findings out. Only `exact` pairings (or explicit overrides) map
//  automatically; everything else is reported for a human, never guessed.
// ─────────────────────────────────────────────────────────────────────────────

public enum MappingConfidence: String, Codable, Hashable, Sendable {
    case exact
    case normalised
    case ambiguous
    case unmatched
}

/// Findings that require (or record) human attention. Serialized into the
/// generated review report — a working artifact, not a tracked file.
public struct ReviewReport: Codable, Sendable {
    public struct FileFinding: Codable, Hashable, Sendable {
        public let file: String
        public let reason: String
        /// Candidate slugs (ambiguous) or resolved slug (normalised/override).
        public let candidates: [String]
    }

    public struct RecordFinding: Codable, Hashable, Sendable {
        public let slug: String
        public let reason: String
        /// True when the finding excluded the record or an asset from the
        /// manifest (as opposed to a note on an included record).
        public let excluded: Bool
    }

    public let exactCount: Int
    public let normalised: [FileFinding]
    public let ambiguous: [FileFinding]
    public let unmatchedFiles: [FileFinding]
    public let recordFindings: [RecordFinding]

    /// True when a human must act before the manifest can be considered whole.
    public var requiresHumanAttention: Bool {
        !ambiguous.isEmpty || !unmatchedFiles.isEmpty || recordFindings.contains { $0.excluded }
    }
}

/// A metadata record with its resolved source files. Absent `posterFile` means
/// the record was NOT excluded but has no poster — the builder rejects that
/// (poster is mandatory, §7); classification keeps the data so the report can
/// say exactly why.
public struct ClassifiedRecord: Hashable, Sendable {
    public let record: SourceMetadataRecord
    public let posterFile: String?
    public let videoFile: String?
    public let confidence: MappingConfidence
}

public struct MappingClassification: Sendable {
    public let records: [ClassifiedRecord]
    public let report: ReviewReport
}

public enum MappingClassifier {
    /// Classifies every metadata record against the poster/video listings.
    /// `overrides` resolve specific files to slugs by prior human decision.
    public static func classify(
        inventory: SourceInventory,
        overrides: MappingOverrides = .empty
    ) -> MappingClassification {
        let slugs = Set(inventory.metadata.map(\.slug))
        var normalised: [ReviewReport.FileFinding] = []
        var ambiguous: [ReviewReport.FileFinding] = []
        var unmatchedFiles: [ReviewReport.FileFinding] = []
        var recordFindings: [ReviewReport.RecordFinding] = []
        var exactCount = 0

        // Resolve each media kind independently: slug → (file, confidence).
        func resolve(kind: MediaKind, files: [String]) -> [String: (file: String, confidence: MappingConfidence)] {
            var bySlug: [String: [(file: String, isExact: Bool)]] = [:]
            let overridden = Dictionary(
                overrides.overrides.filter { $0.kind == kind }.map { ($0.file, $0.slug) },
                uniquingKeysWith: { first, _ in first }
            )

            for file in files.sorted() {
                if let slug = overridden[file] {
                    // Prior human decision (§10): treated as exact, but recorded.
                    bySlug[slug, default: []].append((file, true))
                    normalised.append(.init(file: file, reason: "mapped by tracked override", candidates: [slug]))
                    continue
                }
                guard let candidate = candidateSlug(for: file, kind: kind) else {
                    unmatchedFiles.append(.init(file: file, reason: "unsupported name or extension for \(kind.rawValue)", candidates: []))
                    continue
                }
                guard slugs.contains(candidate.slug) else {
                    unmatchedFiles.append(.init(file: file, reason: "no metadata record for derived slug", candidates: [candidate.slug]))
                    continue
                }
                bySlug[candidate.slug, default: []].append((file, candidate.isExact))
            }

            var resolved: [String: (file: String, confidence: MappingConfidence)] = [:]
            for (slug, candidates) in bySlug {
                if candidates.count > 1 {
                    // Never auto-picked (§10): all candidates go to the report.
                    for candidate in candidates {
                        ambiguous.append(.init(file: candidate.file, reason: "multiple \(kind.rawValue) files resolve to one slug", candidates: [slug]))
                    }
                    continue
                }
                let candidate = candidates[0]
                if candidate.isExact {
                    exactCount += 1
                } else {
                    normalised.append(.init(file: candidate.file, reason: "matched after normalisation", candidates: [slug]))
                }
                resolved[slug] = (candidate.file, candidate.isExact ? .exact : .normalised)
            }
            return resolved
        }

        let posters = resolve(kind: .poster, files: inventory.posterFiles)
        let videos = resolve(kind: .video, files: inventory.videoFiles)

        var records: [ClassifiedRecord] = []
        for record in inventory.metadata.sorted(by: { $0.slug < $1.slug }) {
            guard ExerciseSlug.isCanonicalFormat(record.slug) else {
                recordFindings.append(.init(slug: record.slug, reason: "slug is not in canonical format", excluded: true))
                continue
            }
            let poster = posters[record.slug]
            let video = videos[record.slug]
            if poster == nil {
                recordFindings.append(.init(slug: record.slug, reason: "no poster resolved — poster is mandatory", excluded: true))
            }
            if video == nil {
                recordFindings.append(.init(slug: record.slug, reason: "no video resolved — entry is poster-only", excluded: false))
            }
            let confidences = [poster?.confidence, video?.confidence].compactMap(\.self)
            records.append(ClassifiedRecord(
                record: record,
                posterFile: poster?.file,
                videoFile: video?.file,
                confidence: confidences.contains(.normalised) ? .normalised : .exact
            ))
        }

        return MappingClassification(
            records: records,
            report: ReviewReport(
                exactCount: exactCount,
                normalised: normalised.sorted { $0.file < $1.file },
                ambiguous: ambiguous.sorted { $0.file < $1.file },
                unmatchedFiles: unmatchedFiles.sorted { $0.file < $1.file },
                recordFindings: recordFindings.sorted { $0.slug < $1.slug }
            )
        )
    }

    /// Derives the slug a listing name would map to, and whether the pairing is
    /// byte-exact (`<slug>.<ext>`, optionally under a directory) or required
    /// normalisation (case folding). Wrong extensions yield nil (§9: reported,
    /// never coerced).
    static func candidateSlug(for file: String, kind: MediaKind) -> (slug: String, isExact: Bool)? {
        let baseName = file.split(separator: "/").last.map(String.init) ?? file
        let suffix = "." + kind.fileExtension
        guard baseName.lowercased().hasSuffix(suffix) else { return nil }
        let stem = String(baseName.dropLast(suffix.count))
        let slug = stem.lowercased()
        guard ExerciseSlug.isCanonicalFormat(slug) else { return nil }
        let isExact = stem == slug && baseName.hasSuffix(suffix)
        return (slug, isExact)
    }
}
