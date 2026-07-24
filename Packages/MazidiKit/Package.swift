// swift-tools-version: 6.0
// MazidiKit — core package for Mazidi Performance (ADR-0001).
// The domain/services/sync/persistence-contract targets are platform-neutral
// (Foundation only). MazidiPersistenceGRDB is the durable-store adapter and is the
// single target allowed to import GRDB (ADR-0007) — building the whole package
// therefore requires a GRDB-supported (Apple) platform; the neutral targets remain
// individually buildable elsewhere.
import PackageDescription

let package = Package(
    name: "MazidiKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MazidiFoundations", targets: ["MazidiFoundations"]),
        .library(name: "MazidiDomain", targets: ["MazidiDomain"]),
        .library(name: "MazidiPersistence", targets: ["MazidiPersistence"]),
        .library(name: "MazidiPersistenceGRDB", targets: ["MazidiPersistenceGRDB"]),
        .library(name: "MazidiSync", targets: ["MazidiSync"]),
        .library(name: "MazidiServices", targets: ["MazidiServices"]),
        .library(name: "MazidiNetworking", targets: ["MazidiNetworking"]),
    ],
    dependencies: [
        // Pinned EXACTLY (reproducibility): Package.resolved is not committed for this
        // local package, so the manifest itself is the lockfile — app, package tests and
        // CI all resolve the identical revision. Deliberate upgrades follow the
        // "Updating GRDB" procedure in docs/BUILD_AND_TEST.md.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "MazidiFoundations"),
        .target(name: "MazidiDomain", dependencies: ["MazidiFoundations"]),
        .target(name: "MazidiPersistence", dependencies: ["MazidiDomain", "MazidiFoundations"]),
        .target(name: "MazidiSync", dependencies: ["MazidiDomain", "MazidiPersistence", "MazidiFoundations"]),
        // Leaf adapter (ADR-0007): the only target that may import GRDB. Depends on
        // MazidiSync to map the concrete SyncOperation — no cycle, contracts unchanged.
        .target(name: "MazidiPersistenceGRDB", dependencies: [
            "MazidiPersistence", "MazidiSync", "MazidiDomain", "MazidiFoundations",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "MazidiNetworking", dependencies: ["MazidiDomain", "MazidiFoundations"]),
        .target(name: "MazidiServices", dependencies: [
            "MazidiDomain", "MazidiPersistence", "MazidiSync", "MazidiNetworking", "MazidiFoundations",
        ]),
        .testTarget(name: "MazidiDomainTests", dependencies: ["MazidiDomain"]),
        .testTarget(name: "MazidiSyncTests", dependencies: ["MazidiSync", "MazidiPersistence"]),
        .testTarget(name: "MazidiServicesTests", dependencies: ["MazidiServices"]),
        .testTarget(name: "MazidiPersistenceGRDBTests", dependencies: [
            "MazidiPersistenceGRDB", "MazidiServices",
        ]),
    ]
)
