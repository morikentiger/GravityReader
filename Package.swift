// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GravityReader",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GravityReader",
            path: "Sources/GravityReader",
            resources: [
                .copy("Resources/SpeakerEmbedding.mlpackage")
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        )
    ]
)
