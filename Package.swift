// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Tantivy is a Swift wrapper around the tantivy 0.26.1 full-text search engine.
//
// The C layer is resolved in one of three modes, in priority order:
//
//  1. Local xcframework — if `artifacts/CTantivy.xcframework` exists on disk
//     (e.g. a `scripts/release.sh` dry-run, or a maintainer testing a fresh
//     build), it is consumed as a binary target directly.
//
//  2. Host/dev mode — else, if the host static library
//     `rust/target/release/libtantivy_ffi.a` exists (built with
//     `scripts/build-host.sh`), the C layer links against it. This backs the
//     local/CI test suite; it does not produce a redistributable package.
//
//  3. Distribution mode (the default for consumers) — else the prebuilt
//     xcframework is downloaded from its GitHub Release asset and
//     checksum-verified by SwiftPM. No Rust toolchain, no Git LFS, nothing to
//     compile at app-build time. `scripts/release.sh` rewrites `release` and
//     `checksum` below on each release.

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

// Published binary, downloaded + checksum-verified by SwiftPM on resolve.
// scripts/release.sh rewrites these two lines for each release.
let release  = "0.1.2"
let checksum = "10f2806a240250f5f629edd6db755ebd4d6fd79cca293d4bdaeeb0b6b6d5b864"
let remoteXCFramework =
    "https://github.com/carbon/TantivySwift/releases/download/\(release)/CTantivy.xcframework.zip"

let xcframeworkPath = "artifacts/CTantivy.xcframework"
let hostLibDir = packageRoot.appendingPathComponent("rust/target/release").path
let fm = FileManager.default

let cTarget: Target
if fm.fileExists(atPath: packageRoot.appendingPathComponent(xcframeworkPath).path) {
    // 1. Locally-built xcframework takes precedence (release dry-run / testing).
    cTarget = .binaryTarget(name: "CTantivy", path: xcframeworkPath)
} else if fm.fileExists(atPath: hostLibDir + "/libtantivy_ffi.a") {
    // 2. Host static library. Absolute -L path so it resolves regardless of the
    //    linker's working directory.
    cTarget = .target(
        name: "CTantivy",
        path: "Sources/CTantivy",
        linkerSettings: [
            .unsafeFlags(["-L", hostLibDir, "-ltantivy_ffi"])
        ]
    )
} else {
    // 3. Consumers: download the released, checksum-verified xcframework.
    cTarget = .binaryTarget(name: "CTantivy", url: remoteXCFramework, checksum: checksum)
}

let package = Package(
    name: "Tantivy",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "Tantivy", targets: ["Tantivy"]),
    ],
    targets: [
        cTarget,
        .target(
            name: "Tantivy",
            dependencies: ["CTantivy"],
            // tantivy's static lib needs libiconv on Apple platforms
            // (-lSystem / -lc / -lm are linked implicitly).
            linkerSettings: [
                .linkedLibrary("iconv")
            ]
        ),
        .testTarget(
            name: "TantivyTests",
            dependencies: ["Tantivy"]
        ),
    ]
)
