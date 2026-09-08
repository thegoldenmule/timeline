// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EventStoreSpike",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/mhayes853/swift-uuidv7", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "EventStoreSpike",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "UUIDV7", package: "swift-uuidv7"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
