// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "PhosphorSupport",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "PhosphorGeneration", targets: ["PhosphorGeneration"])
    ],
    dependencies: [
        // PhosphorKit owns the parse/compile/render targets (the single source
        // of truth). PhosphorSupport now only adds AI generation on top.
        .package(url: "https://github.com/schwa/PhosphorKit", branch: "main"),
        .package(url: "https://github.com/schwa/CollaborationKit.git", branch: "main")
    ],
    targets: [
        // AI shader generation, layered on top of PhosphorKit.
        .target(
            name: "PhosphorGeneration",
            dependencies: [
                .product(name: "PhosphorModel", package: "PhosphorKit"),
                .product(name: "PhosphorCompile", package: "PhosphorKit"),
                .product(name: "CollaborationKit", package: "CollaborationKit")
            ],
            resources: [
                .copy("Prompts")
            ]
        ),
        .testTarget(
            name: "PhosphorGenerationTests",
            dependencies: [
                .product(name: "PhosphorModel", package: "PhosphorKit"),
                .product(name: "PhosphorCompile", package: "PhosphorKit"),
                "PhosphorGeneration",
                .product(name: "CollaborationKit", package: "CollaborationKit")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
