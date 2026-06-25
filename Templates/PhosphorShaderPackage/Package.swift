// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PhosphorShaderPackage",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "PhosphorShaderPackage", targets: ["PhosphorShaderPackage"])
    ],
    dependencies: [
        .package(url: "https://github.com/schwa/PhosphorKit", exact: "0.1.0")
    ],
    targets: [
        .target(
            name: "PhosphorShaderPackage",
            dependencies: [
                .product(name: "PhosphorRuntime", package: "PhosphorKit")
            ],
            resources: [
                .copy("Resources/Shader.phosphor")
            ]
        )
    ]
)
