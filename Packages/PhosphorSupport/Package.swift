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
        .library(name: "PhosphorSupport", targets: ["PhosphorSupport"])
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
        .target(
            name: "PhosphorSupport",
            dependencies: [
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalSprocketsUI", package: "MetalSprockets"),
                .product(name: "MetalSprocketsSupport", package: "MetalSprockets"),
                .product(name: "MetalSprocketsAddOns", package: "MetalSprocketsAddOns"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "SwiftTreeSitterLayer", package: "swift-tree-sitter"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "FoundationModelBackends", package: "FoundationModelBackends")
            ]
        ),
        .testTarget(
            name: "PhosphorSupportTests",
            dependencies: ["PhosphorSupport"],
            resources: [
                .copy("Resources")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
