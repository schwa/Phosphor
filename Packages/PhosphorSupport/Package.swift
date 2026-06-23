// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "PhosphorSupport",
    platforms: [
        .iOS(.v27),
        .macOS(.v27),
        .visionOS(.v27)
    ],
    products: [
        .library(name: "PhosphorModel", targets: ["PhosphorModel"]),
        .library(name: "PhosphorCompile", targets: ["PhosphorCompile"]),
        .library(name: "PhosphorRuntime", targets: ["PhosphorRuntime"]),
        .library(name: "PhosphorGeneration", targets: ["PhosphorGeneration"])
    ],
    dependencies: [
        .package(url: "https://github.com/schwa/MetalSprockets", from: "0.1.10"),
        .package(url: "https://github.com/schwa/MetalSprocketsAddOns", from: "0.1.11"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", branch: "master"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", branch: "master"),
        .package(url: "https://github.com/schwa/FoundationModelBackends.git", branch: "main")
    ],
    targets: [
        // Leaf: core data model. No Metal, no external generation deps.
        .target(
            name: "PhosphorModel",
            resources: [
                .copy("Resources/BuiltinTextures")
            ]
        ),
        // Parsing, source assembly, and Metal compilation. Owns Phosphor.h.
        .target(
            name: "PhosphorCompile",
            dependencies: [
                "PhosphorModel",
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "SwiftTreeSitterLayer", package: "swift-tree-sitter"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml")
            ],
            resources: [
                .copy("Resources/Phosphor.h")
            ]
        ),
        // Live rendering pipeline + audio capture.
        .target(
            name: "PhosphorRuntime",
            dependencies: [
                "PhosphorModel",
                "PhosphorCompile",
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalSprocketsUI", package: "MetalSprockets"),
                .product(name: "MetalSprocketsSupport", package: "MetalSprockets"),
                .product(name: "MetalSprocketsAddOns", package: "MetalSprocketsAddOns")
            ]
        ),
        // AI shader generation.
        .target(
            name: "PhosphorGeneration",
            dependencies: [
                "PhosphorModel",
                "PhosphorCompile",
                .product(name: "FoundationModelBackends", package: "FoundationModelBackends")
            ]
        ),
        .testTarget(
            name: "PhosphorSupportTests",
            dependencies: [
                "PhosphorModel",
                "PhosphorCompile",
                "PhosphorRuntime",
                "PhosphorGeneration"
            ],
            resources: [
                .copy("Resources")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
