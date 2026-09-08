// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "timeline-mcp-spike",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // The SDK's HTTP server transports are framework-agnostic; we need NIO ourselves to listen on a socket.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .executableTarget(
            name: "TimelineMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
