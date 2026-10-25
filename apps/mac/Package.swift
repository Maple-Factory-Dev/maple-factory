// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MapleFactory",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The terminal for live sessions, until libghostty.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "MapleFactory",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/MapleFactory",
            resources: [.process("Resources")]
        )
    ]
)
