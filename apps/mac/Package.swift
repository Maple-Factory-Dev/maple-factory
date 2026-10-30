// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MapleFactory",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // What the Mac app and the coming iOS app share: the wire protocol, the factory API, sign-in storage.
        .library(name: "MapleKit", targets: ["MapleKit"]),
    ],
    dependencies: [
        // The terminal for live sessions, until libghostty.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
        // Updates: the app checks maplefactory.dev's appcast (scripts/release.mjs publishes it).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        // Foundation and Security only, so it builds for iOS (scripts/check-ios.sh).
        .target(
            name: "MapleKit",
            path: "Sources/MapleKit"
        ),
        .testTarget(
            name: "MapleKitTests",
            dependencies: ["MapleKit"],
            path: "Tests/MapleKitTests"
        ),
        .executableTarget(
            name: "MapleFactory",
            dependencies: [
                "MapleKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MapleFactory",
            resources: [.process("Resources")],
            // SwiftUI's VideoPlayer (video proofs) needs AVKit itself linked, or it can't load AVPlayerView.
            linkerSettings: [.linkedFramework("AVKit")]
        ),
        .testTarget(
            name: "MapleFactoryTests",
            dependencies: ["MapleFactory"],
            path: "Tests/MapleFactoryTests"
        ),
    ]
)
