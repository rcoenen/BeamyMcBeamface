// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Beamy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BeamyKit", targets: ["BeamyKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "BeamyKit",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
    ]
)
