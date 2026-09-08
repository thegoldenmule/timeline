// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompositorSpike",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "CompositorSpike",
            path: "Sources/CompositorSpike",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
