// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VinylDiggerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VinylDiggerKit", targets: ["VinylDiggerKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "VinylDiggerKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "VinylDiggerKitTests",
            dependencies: ["VinylDiggerKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
