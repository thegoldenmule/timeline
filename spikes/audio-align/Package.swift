// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "audio-align",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "AlignCore", linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("AVFoundation")]),
        .executableTarget(name: "audio-align", dependencies: ["AlignCore"]),
        .testTarget(name: "AlignCoreTests", dependencies: ["AlignCore"]),
    ],
    swiftLanguageModes: [.v6]
)
