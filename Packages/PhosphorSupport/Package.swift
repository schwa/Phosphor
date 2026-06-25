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
        .library(name: "PhosphorGeneration", targets: ["PhosphorGeneration"]),
        .library(name: "PhosphorMetalSprockets", targets: ["PhosphorMetalSprockets"])
    ],
    dependencies: [
        // PhosphorKit owns the parse/compile/render targets (the single source
        // of truth). PhosphorSupport adds AI generation and the MetalSprockets
        // render host on top. PhosphorKit itself is MetalSprockets-free.
        .package(url: "https://github.com/schwa/PhosphorKit", branch: "main"),
        .package(url: "https://github.com/schwa/CollaborationKit.git", branch: "main"),
        .package(url: "https://github.com/schwa/MetalSprockets", from: "0.1.10")
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
        // MetalSprockets render host: wraps PhosphorKit's raw-Metal
        // PhosphorRenderer inside a MetalSprockets RenderView, so the app keeps
        // frame timing (and, later, video import/export) while PhosphorKit
        // stays MetalSprockets-free.
        .target(
            name: "PhosphorMetalSprockets",
            dependencies: [
                .product(name: "PhosphorModel", package: "PhosphorKit"),
                .product(name: "PhosphorCompile", package: "PhosphorKit"),
                .product(name: "PhosphorRuntime", package: "PhosphorKit"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalSprocketsUI", package: "MetalSprockets")
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
