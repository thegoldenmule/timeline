// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PreviewUpdateSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "PreviewUpdateSpike",
            path: "Sources/PreviewUpdateSpike",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
