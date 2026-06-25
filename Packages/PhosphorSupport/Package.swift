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
        .library(name: "PhosphorEditorSupport", targets: ["PhosphorEditorSupport"])
    ],
    dependencies: [
        // PhosphorKit owns the parse/compile/render targets (the single source
        // of truth). PhosphorSupport adds AI generation and the MetalSprockets
        // render host on top. PhosphorKit itself is MetalSprockets-free.
        .package(url: "https://github.com/schwa/PhosphorKit", branch: "main"),
        .package(url: "https://github.com/schwa/CollaborationKit.git", branch: "main"),
        .package(url: "https://github.com/schwa/MetalSprockets", from: "0.1.10"),
        // tree-sitter powers PhosphorInterface (the declarations-only view of
        // Phosphor.h shown to the model) and the editor's syntax highlighting.
        // Lives here, not in PhosphorKit, so embedders don't drag tree-sitter
        // into their binaries.
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", branch: "master"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", branch: "master")
    ],
    targets: [
        // AI shader generation, layered on top of PhosphorKit.
        .target(
            name: "PhosphorGeneration",
            dependencies: [
                .product(name: "PhosphorModel", package: "PhosphorKit"),
                .product(name: "PhosphorCompile", package: "PhosphorKit"),
                .product(name: "CollaborationKit", package: "CollaborationKit"),
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
        // Misfit-toys target: cross-cutting app-side helpers that don't belong
        // in PhosphorKit (they pull tree-sitter / SwiftUI) and aren't AI
        // generation. First residents: the syntax-highlighted source view.
        .target(
            name: "PhosphorEditorSupport",
            dependencies: [
                .product(name: "PhosphorModel", package: "PhosphorKit"),
                .product(name: "PhosphorCompile", package: "PhosphorKit"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "SwiftTreeSitterLayer", package: "swift-tree-sitter"),
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
        )
    ],
    swiftLanguageModes: [.v6]
)
