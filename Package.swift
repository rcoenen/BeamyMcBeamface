// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Beamy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BeamyKit", targets: ["BeamyKit"]),
        .executable(name: "beamy", targets: ["Beamy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.5.0"),
        .package(url: "https://github.com/onevcat/Rainbow", from: "4.0.0"),
        .package(url: "https://github.com/migueldeicaza/TermKit.git", branch: "main"),
    ],
    targets: [
        // Shared library
        .target(
            name: "BeamyKit",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        // CLI executable
        .executableTarget(
            name: "Beamy",
            dependencies: [
                "BeamyKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Rainbow", package: "Rainbow"),
                .product(name: "TermKit", package: "TermKit"),
            ]
        ),
        .testTarget(
            name: "BeamyKitTests",
            dependencies: ["BeamyKit"]
        ),
    ]
)
