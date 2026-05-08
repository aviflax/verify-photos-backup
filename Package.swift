// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "phobato",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/soto-project/soto.git", from: "7.14.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "phobato",
            dependencies: [
                .product(name: "SotoS3", package: "soto"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
