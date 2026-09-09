// swift-tools-version: 6.2
// Phase 0 declares every target, product, and external dependency up front so that
// module agents never edit this file. See docs/design/implementation-plan.md and
// docs/design/conventions.md.
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "Timeline",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TimelineCore", targets: ["TimelineCore"]),
        .library(name: "Contracts", targets: ["Contracts"]),
        .library(name: "ContractsTestSupport", targets: ["ContractsTestSupport"]),
        .library(name: "ProjectStore", targets: ["ProjectStore"]),
        .library(name: "RenderKit", targets: ["RenderKit"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "AudioAlign", targets: ["AudioAlign"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "PublishKit", targets: ["PublishKit"]),
        .library(name: "TimelineUI", targets: ["TimelineUI"]),
        .executable(name: "TimelineApp", targets: ["TimelineApp"]),
        .executable(name: "timeline-mcp", targets: ["TimelineMCPProxy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.0"),
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage", from: "14.0.0"),
    ],
    targets: [
        // MARK: Shared foundation (Phase 0)

        // Pure Swift, Foundation only. The normative model in docs/design/timeline-model.md.
        .target(name: "TimelineCore", swiftSettings: strict),
        .testTarget(
            name: "TimelineCoreTests",
            dependencies: ["TimelineCore"],
            resources: [.copy("../../Fixtures")],
            swiftSettings: strict),

        // Protocols and DTOs every leaf module talks through. May import AVFoundation/CoreGraphics.
        .target(
            name: "Contracts",
            dependencies: ["TimelineCore"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreGraphics")]),
        // In-memory fakes for every protocol plus the synthetic TestMedia generator.
        .target(
            name: "ContractsTestSupport",
            dependencies: ["TimelineCore", "Contracts"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreImage")]),
        .testTarget(
            name: "ContractsTests",
            dependencies: ["Contracts", "ContractsTestSupport"],
            swiftSettings: strict),

        // MARK: Leaf modules (Phase 1). Import only TimelineCore and Contracts, never a sibling.

        .target(
            name: "ProjectStore",
            dependencies: [
                "TimelineCore", "Contracts",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: strict),
        .testTarget(
            name: "ProjectStoreTests",
            dependencies: ["ProjectStore", "ContractsTestSupport", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict),

        .target(
            name: "RenderKit",
            dependencies: ["TimelineCore", "Contracts"],
            swiftSettings: strict,
            linkerSettings: [
                .linkedFramework("AVFoundation"), .linkedFramework("CoreImage"),
                .linkedFramework("CoreText"), .linkedFramework("Metal"), .linkedFramework("CoreMedia"),
            ]),
        .testTarget(
            name: "RenderKitTests",
            dependencies: [
                "RenderKit", "ContractsTestSupport",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            swiftSettings: strict),

        .target(
            name: "MediaKit",
            dependencies: [
                "TimelineCore", "Contracts",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
            ],
            swiftSettings: strict,
            linkerSettings: [
                .linkedFramework("AVFoundation"), .linkedFramework("Speech"),
                .linkedFramework("Vision"), .linkedFramework("CryptoKit"),
            ]),
        .testTarget(
            name: "MediaKitTests",
            dependencies: ["MediaKit", "ContractsTestSupport"],
            swiftSettings: strict),

        .target(
            name: "AudioAlign",
            dependencies: ["TimelineCore", "Contracts"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("AVFoundation")]),
        .testTarget(
            name: "AudioAlignTests",
            dependencies: ["AudioAlign", "ContractsTestSupport"],
            swiftSettings: strict),

        .target(
            name: "PublishKit",
            dependencies: [
                "TimelineCore", "Contracts",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("CryptoKit")]),
        .testTarget(
            name: "PublishKitTests",
            dependencies: ["PublishKit", "ContractsTestSupport"],
            resources: [.copy("Transcripts")],
            swiftSettings: strict),

        .target(
            name: "AgentKit",
            dependencies: [
                "TimelineCore", "Contracts",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            resources: [.copy("Skills")],
            swiftSettings: strict),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit", "ContractsTestSupport"],
            resources: [.copy("Transcripts")],
            swiftSettings: strict),
        // Thin stdio MCP proxy that forwards to the running app's HTTP endpoint.
        .executableTarget(
            name: "TimelineMCPProxy",
            dependencies: ["AgentKit"],
            swiftSettings: strict),

        .target(
            name: "TimelineUI",
            dependencies: [
                "TimelineCore", "Contracts",
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
            ],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("MetalKit")]),
        .testTarget(
            name: "TimelineUITests",
            dependencies: [
                "TimelineUI", "ContractsTestSupport",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            swiftSettings: strict),

        // MARK: Composition root (Phase 0.5 skeleton, Phase 2 integration)

        .executableTarget(
            name: "TimelineApp",
            dependencies: [
                "TimelineCore", "Contracts", "ContractsTestSupport",
                "ProjectStore", "RenderKit", "MediaKit", "AudioAlign", "AgentKit", "TimelineUI", "PublishKit",
            ],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("AVKit")]),
    ],
    swiftLanguageModes: [.v6]
)
