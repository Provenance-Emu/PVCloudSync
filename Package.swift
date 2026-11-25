// swift-tools-version:5.9
import Foundation
import PackageDescription

// A version tag resolves to the prebuilt XCFrameworks from that tag's GitHub release;
// `main` always builds from source. The release workflow fills this in on the tagged
// commit only, so it stays `nil` on every branch.
// Set PV_BUILD_FROM_SOURCE=1 to build a tagged version from source instead.
let binaryRelease: (version: String, checksums: [String: String])? = ("1.1.2", ["PVCloudSync": "392d56d0fa3805df14b3b2eee1f44785decc9a83b03b283ce6e158fbedea5078", "PVLibraryMetadata": "dbd08070de76130946266c1608fa28369a51170a8701f252951169855a92842a"])

let environment = ProcessInfo.processInfo.environment
let buildFromSource = binaryRelease == nil || environment["PV_BUILD_FROM_SOURCE"] != nil
// The release workflow builds the frameworks it publishes from dynamic products, one
// module at a time, and names the ones already built so later modules link them
// instead of compiling them in again.
let buildingRelease = environment["PV_XCFRAMEWORK_BUILD"] != nil
let libraryType: Product.Library.LibraryType? = buildingRelease ? .dynamic : nil
let prebuilt = Set((environment["PV_XCFRAMEWORK_PREBUILT"] ?? "").split(separator: " ").map(String.init))

let module: (Target) -> Target = { source in
    prebuilt.contains(source.name)
        ? .binaryTarget(name: source.name, path: ".xcframework-build/\(source.name).xcframework")
        : source
}
// A product made only of a prebuilt framework cannot ask for a linkage type.
let libraryTypeFor: (String) -> Product.Library.LibraryType? = { module in
    prebuilt.contains(module) ? nil : libraryType
}

let syncRules: Target.Dependency = .product(name: "PVSyncRules", package: "PVSyncRules")

let sourceTargets: [Target] = [
    module(.target(name: "PVLibraryMetadata")),
    module(.target(name: "PVCloudSync", dependencies: [syncRules]))
] + (buildingRelease ? [] : [
    .testTarget(name: "PVLibraryMetadataTests", dependencies: ["PVLibraryMetadata"], resources: [.copy("Fixtures")]),
    .testTarget(name: "PVCloudSyncTests", dependencies: ["PVCloudSync", syncRules])
])

let binaryTargets: [Target] = binaryRelease.map { release in
    release.checksums.sorted { $0.key < $1.key }.map { module, checksum in
        .binaryTarget(
            name: module,
            url: "https://github.com/Provenance-Emu/PVCloudSync/releases/download/\(release.version)/\(module).xcframework.zip",
            checksum: checksum
        )
    } + [
        // What the prebuilt frameworks link against.
        .target(name: "PVCloudSyncDependencies", dependencies: [syncRules], path: "Sources/BinaryDependencies")
    ]
} ?? []

let package = Package(
    name: "PVCloudSync",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    // Product names are the same in both modes, so consumers never change.
    products: buildFromSource ? [
        .library(name: "PVCloudSync", type: libraryTypeFor("PVCloudSync"), targets: ["PVCloudSync"]),
        .library(name: "PVLibraryMetadata", type: libraryTypeFor("PVLibraryMetadata"), targets: ["PVLibraryMetadata"])
    ] : [
        .library(name: "PVCloudSync", targets: ["PVCloudSync", "PVCloudSyncDependencies"]),
        .library(name: "PVLibraryMetadata", targets: ["PVLibraryMetadata"])
    ],
    dependencies: [
        // 1.0.3 is the first PVSyncRules release with a prebuilt framework. An older one
        // would be compiled into PVCloudSync's own framework.
        .package(url: "https://github.com/Provenance-Emu/PVSyncRules.git", .upToNextMajor(from: "1.0.3"))
    ],
    targets: buildFromSource ? sourceTargets : binaryTargets
)
