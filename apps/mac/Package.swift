// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MapleFactory",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The terminal for live sessions, until libghostty.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
        // Updates: the app checks maplefactory.dev's appcast (scripts/release.mjs publishes it).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "MapleFactory",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MapleFactory",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MapleFactoryTests",
            dependencies: ["MapleFactory"],
            path: "Tests/MapleFactoryTests"
        ),
    ]
)
