// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PhosphorSupport",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PhosphorSupport",
            targets: ["PhosphorSupport"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", branch: "master"),
    ],
    targets: [
        .target(
            name: "PhosphorSupport",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
            ]
        ),
        .testTarget(
            name: "PhosphorSupportTests",
            dependencies: ["PhosphorSupport"]
        ),
    ]
)
