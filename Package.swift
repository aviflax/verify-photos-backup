// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "verify-photos-backup",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/soto-project/soto.git", from: "7.14.0"),
    ],
    targets: [
        .executableTarget(
            name: "verify-backup",
            dependencies: [
                .product(name: "SotoS3", package: "soto"),
            ]
        ),
    ]
)
