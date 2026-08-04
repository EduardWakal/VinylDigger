// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiggerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiggerKit", targets: ["DiggerKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "DiggerKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "DiggerKitTests",
            dependencies: ["DiggerKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
