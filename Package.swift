// swift-tools-version: 6.2
import PackageDescription
import CompilerPluginSupport
import Foundation

// Tantivy is a Swift wrapper around the tantivy 0.26.1 full-text search engine.
//
// It builds in one of two modes:
//
//  * Distribution mode — when `artifacts/CTantivy.xcframework` exists, the C
//    layer is consumed as a prebuilt XCFramework binary target. This is the
//    mode that supports macOS, iOS and iPadOS. Build the xcframework with
//    `scripts/build-xcframework.sh` (requires full Xcode).
//
//  * Host/dev mode — otherwise the C layer links against the host static
//    library at `rust/target/release/libtantivy_ffi.a`, built with
//    `scripts/build-host.sh`. This is for running the test suite locally on
//    the Mac you build on; it does not produce a redistributable package.

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let xcframeworkPath = "artifacts/CTantivy.xcframework"
let haveXCFramework = FileManager.default.fileExists(
    atPath: packageRoot.appendingPathComponent(xcframeworkPath).path
)

let cTarget: Target
if haveXCFramework {
    cTarget = .binaryTarget(name: "CTantivy", path: xcframeworkPath)
} else {
    // Link the host static library directly. Absolute -L path so it resolves
    // regardless of the linker's working directory.
    let hostLibDir = packageRoot.appendingPathComponent("rust/target/release").path
    cTarget = .target(
        name: "CTantivy",
        path: "Sources/CTantivy",
        linkerSettings: [
            .unsafeFlags(["-L", hostLibDir, "-ltantivy_ffi"])
        ]
    )
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
    dependencies: [
        // For the @Indexable macro (compile-time only; the macro plugin runs on
        // the build host, it is not linked into your app).
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        cTarget,
        // Compiler-plugin target implementing @Indexable / @Field.
        .macro(
            name: "TantivyMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "Tantivy",
            dependencies: ["CTantivy", "TantivyMacrosPlugin"],
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
