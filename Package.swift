// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GravityReader",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GravityReader", targets: ["GravityReader"])
    ],
    targets: [
        .target(
            name: "GravityReader",
            path: "Sources/GravityReader",
            resources: [
                .copy("Resources/SpeakerEmbedding.mlpackage")
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        ),
        .executableTarget(
            name: "GravityReaderMain",
            dependencies: ["GravityReader"],
            path: "Sources/GravityReaderMain",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        ),
        .testTarget(
            name: "GravityReaderTests",
            dependencies: ["GravityReader"],
            path: "Tests/GravityReaderTests"
        )
    ]
)
