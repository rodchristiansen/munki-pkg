// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "munkipkg",
    platforms: [
        .macOS("14.0") // macOS 14.0 Sonoma minimum for full Swift 6 concurrency features
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "munkipkg",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "munkipkg",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "munkipkgTests",
            dependencies: ["munkipkg"],
            path: "munkipkgTests",
            resources: [
                .copy("fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)