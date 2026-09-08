// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "speechspike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "speechspike",
            path: "Sources/speechspike",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
