// ─────────────────────────────────────────────────────────────────────────────
//  mazidi-content-audit — read-only source-library audit & catalogue generator
//  (ADR-0010 "Tooling and layout").
//
//  Reads the three source zips IN PLACE via `zipinfo`/`unzip -p` streams — it
//  never writes, extracts, renames, or otherwise touches anything inside the
//  source directory. All output goes to the git-ignored working directory
//  (and, with --emit-into, the tracked catalogue directory).
//
//  macOS-only developer tooling: it shells out to system `zipinfo`/`unzip` and
//  uses CryptoKit for SHA-256 (same accepted-exception reasoning as MazidiAuth).
// ─────────────────────────────────────────────────────────────────────────────

#if os(macOS)
import CryptoKit
import Foundation
import MazidiContent

struct AuditFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Arguments

struct Arguments {
    var source: URL
    var work: URL
    var emitInto: URL?
    var previous: URL?
    var overrides: URL?

    static func parse(_ raw: [String]) throws -> Arguments {
        var values: [String: String] = [:]
        var index = 0
        while index < raw.count {
            let flag = raw[index]
            guard flag.hasPrefix("--"), index + 1 < raw.count else {
                throw AuditFailure("Unexpected argument '\(flag)'. Usage: mazidi-content-audit --source <dir> --work <dir> [--emit-into <dir>] [--previous <catalogue.json>] [--overrides <file>]")
            }
            values[flag] = raw[index + 1]
            index += 2
        }
        guard let source = values["--source"], let work = values["--work"] else {
            throw AuditFailure("--source and --work are required")
        }
        return Arguments(
            source: URL(fileURLWithPath: source).standardizedFileURL,
            work: URL(fileURLWithPath: work).standardizedFileURL,
            emitInto: values["--emit-into"].map { URL(fileURLWithPath: $0).standardizedFileURL },
            previous: values["--previous"].map { URL(fileURLWithPath: $0).standardizedFileURL },
            overrides: values["--overrides"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        )
    }
}

// MARK: - Safety guards (ADR-0010: the source directory is strictly read-only)

func assertSafe(_ args: Arguments) throws {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: args.source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw AuditFailure("Source directory does not exist: \(args.source.path)")
    }
    // The source of record must never live inside the repository the outputs
    // land in — that is what could get it committed. (An unrelated repo higher
    // up, e.g. a home-directory dotfiles repo, is not a risk and not blocked.)
    func repoRoot(containing url: URL) -> URL? {
        var probe = url
        while probe.pathComponents.count > 1 {
            if fm.fileExists(atPath: probe.appendingPathComponent(".git").path) { return probe }
            probe.deleteLastPathComponent()
        }
        return nil
    }
    if fm.fileExists(atPath: args.source.appendingPathComponent(".git").path) {
        throw AuditFailure("Refusing to run: source directory is itself a git repository")
    }
    for (name, destination) in [("work", args.work), ("emit", args.emitInto ?? args.work)] {
        if destination.path == args.source.path || destination.path.hasPrefix(args.source.path + "/") {
            throw AuditFailure("Refusing to run: \(name) directory is inside the read-only source directory")
        }
        if let root = repoRoot(containing: destination),
           args.source.path == root.path || args.source.path.hasPrefix(root.path + "/") {
            throw AuditFailure("Refusing to run: source directory is inside the output repository (\(root.path))")
        }
    }
}

// MARK: - Zip access (read-only streams; never extraction into the source)

func run(_ tool: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw AuditFailure("\(tool) \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(message)")
    }
    return data
}

func listEntries(of zip: URL) throws -> [String] {
    let data = try run("/usr/bin/zipinfo", ["-1", zip.path])
    guard let text = String(data: data, encoding: .utf8) else {
        throw AuditFailure("Could not decode listing of \(zip.lastPathComponent)")
    }
    return text.split(separator: "\n").map(String.init)
}

func streamEntry(_ entry: String, from zip: URL) throws -> Data {
    try run("/usr/bin/unzip", ["-p", zip.path, entry])
}

func fileSHA256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Main

func main() throws {
    let args = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
    try assertSafe(args)
    let fm = FileManager.default

    // Locate the three source archives by their fixed roles.
    let zips = try fm.contentsOfDirectory(at: args.source, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "zip" }
    func requireZip(_ predicate: (String) -> Bool, role: String) throws -> URL {
        let matches = zips.filter { predicate($0.lastPathComponent) }
        guard matches.count == 1 else {
            throw AuditFailure("Expected exactly one \(role) zip in source, found \(matches.count)")
        }
        return matches[0]
    }
    let metadataZip = try requireZip({ $0 == "full-library-metadata.zip" }, role: "metadata")
    let postersZip = try requireZip({ $0 == "full-library-posters.zip" }, role: "posters")
    let videosZip = try requireZip({ $0 != "full-library-metadata.zip" && $0 != "full-library-posters.zip" }, role: "video library")

    // Fingerprint the archives (replaces timestamps for determinism, §3).
    print("Fingerprinting source archives…")
    let fingerprint = [
        "metadata.zip": try fileSHA256(of: metadataZip),
        "posters.zip": try fileSHA256(of: postersZip),
        "videos.zip": try fileSHA256(of: videosZip),
    ]

    // Inventory.
    let metadataData = try streamEntry("metadata.json", from: metadataZip)
    let metadata = try JSONDecoder().decode([SourceMetadataRecord].self, from: metadataData)
    let posterFiles = try listEntries(of: postersZip)
    let videoFiles = try listEntries(of: videosZip)
    let inventory = SourceInventory(metadata: metadata, posterFiles: posterFiles, videoFiles: videoFiles)
    print("Inventory: \(metadata.count) metadata records, \(inventory.posterFiles.count) posters, \(inventory.videoFiles.count) videos")

    // Overrides + previous catalogue.
    var overrides = MappingOverrides.empty
    if let overridesURL = args.overrides, fm.fileExists(atPath: overridesURL.path) {
        overrides = try CatalogueSerialization.decode(MappingOverrides.self, from: Data(contentsOf: overridesURL))
    }
    var previous: ExerciseCatalogue?
    if let previousURL = args.previous, fm.fileExists(atPath: previousURL.path) {
        previous = try CatalogueSerialization.decode(ExerciseCatalogue.self, from: Data(contentsOf: previousURL))
    }

    // Classify, digest only what classification resolved, build.
    let classification = MappingClassifier.classify(inventory: inventory, overrides: overrides)
    print("Digesting resolved assets (streams, no extraction)…")
    var digests: [String: AssetDigest] = [:]
    for (index, classified) in classification.records.enumerated() {
        for (file, zip) in [(classified.posterFile, postersZip), (classified.videoFile, videosZip)] {
            guard let file, digests[file] == nil else { continue }
            let bytes = try streamEntry(file, from: zip)
            digests[file] = AssetDigest(sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), bytes: bytes.count)
        }
        if (index + 1) % 50 == 0 { print("  …\(index + 1)/\(classification.records.count)") }
    }

    let result = try CatalogueBuilder.build(
        classification: classification,
        digests: digests,
        previous: previous,
        sourceFingerprint: fingerprint
    )

    // Write outputs — working directory always; tracked directory on request.
    try fm.createDirectory(at: args.work, withIntermediateDirectories: true)
    func write(_ data: Data, to directory: URL, name: String) throws {
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    try write(CatalogueSerialization.encode(result.catalogue), to: args.work, name: "catalogue.json")
    try write(CatalogueSerialization.encode(result.manifest), to: args.work, name: "media-manifest.json")
    try write(CatalogueSerialization.encode(result.report), to: args.work, name: "review-report.json")
    try write(Data(reviewMarkdown(result.report).utf8), to: args.work, name: "review-report.md")

    if let emit = args.emitInto {
        try fm.createDirectory(at: emit, withIntermediateDirectories: true)
        try write(CatalogueSerialization.encode(result.catalogue), to: emit, name: "catalogue.json")
        try write(CatalogueSerialization.encode(result.manifest), to: emit, name: "media-manifest.json")
        let overridesFile = emit.appendingPathComponent("mapping-overrides.json")
        if !fm.fileExists(atPath: overridesFile.path) {
            try CatalogueSerialization.encode(MappingOverrides.empty).write(to: overridesFile, options: .atomic)
        }
    }

    let report = result.report
    print("""
    Catalogue v\(result.catalogue.catalogueVersion): \(result.catalogue.records.count) records \
    (\(result.catalogue.records.filter { $0.availabilityStatus == .available }.count) available, \
    \(result.catalogue.records.filter { $0.availabilityStatus == .posterOnly }.count) poster-only, \
    \(result.catalogue.records.filter { $0.availabilityStatus == .retired }.count) retired)
    Review: \(report.exactCount) exact · \(report.normalised.count) normalised · \(report.ambiguous.count) ambiguous · \
    \(report.unmatchedFiles.count) unmatched files · \(report.recordFindings.count) record findings
    Human attention required: \(report.requiresHumanAttention ? "YES — see review-report.md" : "no")
    """)
}

func reviewMarkdown(_ report: ReviewReport) -> String {
    var lines = ["# Source-library review report", ""]
    lines.append("- Exact pairings: \(report.exactCount)")
    lines.append("- Requires human attention: \(report.requiresHumanAttention ? "**yes**" : "no")")
    for (title, findings) in [("Normalised", report.normalised), ("Ambiguous", report.ambiguous), ("Unmatched files", report.unmatchedFiles)] {
        lines.append("")
        lines.append("## \(title) (\(findings.count))")
        for finding in findings {
            lines.append("- `\(finding.file)` — \(finding.reason)\(finding.candidates.isEmpty ? "" : " (candidates: \(finding.candidates.joined(separator: ", ")))")")
        }
    }
    lines.append("")
    lines.append("## Record findings (\(report.recordFindings.count))")
    for finding in report.recordFindings {
        lines.append("- `\(finding.slug)` — \(finding.reason)\(finding.excluded ? " **[excluded]**" : "")")
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
#else
print("mazidi-content-audit is macOS-only developer tooling.")
#endif
