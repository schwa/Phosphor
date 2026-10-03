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
        .library(name: "PhosphorMetalSprockets", targets: ["PhosphorMetalSprockets"]),
        .library(name: "PhosphorEditorSupport", targets: ["PhosphorEditorSupport"]),
        .library(name: "SourceEditor", targets: ["SourceEditor"]),
        .library(name: "PhosphorVideo", targets: ["PhosphorVideo"])
    ],
    dependencies: [
        .package(url: "https://github.com/schwa/PhosphorKit", from: "0.2.0"),
        .package(url: "https://github.com/schwa/CollaborationKit", from: "0.2.4"),
        .package(url: "https://github.com/schwa/MetalSprockets", from: "0.2.0"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
        // No tagged release ships a Package.swift; SwiftPM support is master-only, so pin by revision.
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", revision: "c009222808634c1014f82438d4883753516a2c24"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", exact: "0.7.0")
    ],
    targets: [
        // AI shader generation, layered on top of PhosphorKit.
        .target(
            name: "PhosphorGeneration",
            dependencies: [
                .product(name: "PhosphorModel", package: "PhosphorKit"),
                .product(name: "PhosphorCompile", package: "PhosphorKit"),
                .product(name: "CollaborationKit", package: "CollaborationKit"),
                .product(name: "CollaborationKitUI", package: "CollaborationKit"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp")
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
        // Offline, deterministic rendering of a shader to a movie file.
        .target(
            name: "PhosphorVideo",
            dependencies: [
                .product(name: "PhosphorModel", package: "PhosphorKit"),
                .product(name: "PhosphorCompile", package: "PhosphorKit"),
                .product(name: "PhosphorRuntime", package: "PhosphorKit")
            ]
        ),
        // General-purpose syntax-highlighted source editor. Knows nothing
        // about Phosphor, Metal, or any particular grammar: callers supply a
        // SourceLanguage and a SyntaxPalette.
        .target(
            name: "SourceEditor",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter")
            ]
        ),
        // Phosphor's flavouring of SourceEditor: the Metal (C++ + TOML
        // front-matter) language definition.
        .target(
            name: "PhosphorEditorSupport",
            dependencies: [
                "SourceEditor",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml")
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
        ),
        .testTarget(
            name: "PhosphorMetalSprocketsTests",
            dependencies: ["PhosphorMetalSprockets"]
        ),
        .testTarget(
            name: "PhosphorVideoTests",
            dependencies: ["PhosphorVideo"]
        ),
        .testTarget(
            name: "SourceEditorTests",
            dependencies: [
                "SourceEditor",
                "PhosphorEditorSupport"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
