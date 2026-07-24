// swift-tools-version: 6.0
// MazidiKit — platform-neutral core for Mazidi Performance (ADR-0001).
// Must build with `swift build` on macOS, Linux and Windows: Foundation only,
// no UIKit/SwiftUI/Apple-only frameworks.
import PackageDescription

let package = Package(
    name: "MazidiKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MazidiFoundations", targets: ["MazidiFoundations"]),
        .library(name: "MazidiDomain", targets: ["MazidiDomain"]),
        .library(name: "MazidiPersistence", targets: ["MazidiPersistence"]),
        .library(name: "MazidiSync", targets: ["MazidiSync"]),
        .library(name: "MazidiServices", targets: ["MazidiServices"]),
        .library(name: "MazidiNetworking", targets: ["MazidiNetworking"]),
    ],
    targets: [
        .target(name: "MazidiFoundations"),
        .target(name: "MazidiDomain", dependencies: ["MazidiFoundations"]),
        .target(name: "MazidiPersistence", dependencies: ["MazidiDomain", "MazidiFoundations"]),
        .target(name: "MazidiSync", dependencies: ["MazidiDomain", "MazidiPersistence", "MazidiFoundations"]),
        .target(name: "MazidiNetworking", dependencies: ["MazidiDomain", "MazidiFoundations"]),
        .target(name: "MazidiServices", dependencies: [
            "MazidiDomain", "MazidiPersistence", "MazidiSync", "MazidiNetworking", "MazidiFoundations",
        ]),
        .testTarget(name: "MazidiDomainTests", dependencies: ["MazidiDomain"]),
        .testTarget(name: "MazidiSyncTests", dependencies: ["MazidiSync", "MazidiPersistence"]),
        .testTarget(name: "MazidiServicesTests", dependencies: ["MazidiServices"]),
    ]
)
