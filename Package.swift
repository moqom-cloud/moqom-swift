// swift-tools-version: 6.0

import PackageDescription

// Swift 6 language mode is not negotiable here: the SDK hands frames between a
// render callback, an encoder queue, and a network actor, which is precisely
// the shape of code that data-race safety exists to catch. An SDK that cannot
// itself be compiled in the mode its users are adopting is already dated.
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "MoqomKit",
    // visionOS is listed because the room, layer, and session logic is shared
    // with it verbatim; only the capture backend differs. See README for what
    // is actually reachable without an iOS/visionOS SDK installed.
    platforms: [.iOS(.v17), .macOS(.v14), .visionOS(.v1), .tvOS(.v17)],
    products: [
        .library(name: "MoqomKit", targets: ["MoqomKit"]),
        .library(name: "MoqomLoopback", targets: ["MoqomLoopback"]),
    ],
    targets: [
        .target(name: "MoqomCore", swiftSettings: strict),
        .target(name: "MoqomKit", dependencies: ["MoqomCore"], swiftSettings: strict),
        .target(
            name: "MoqomLoopback",
            dependencies: ["MoqomCore", "MoqomKit"],
            swiftSettings: strict
        ),
        .testTarget(name: "MoqomCoreTests", dependencies: ["MoqomCore"], swiftSettings: strict),
        .testTarget(
            name: "MoqomKitTests",
            dependencies: ["MoqomKit", "MoqomLoopback"],
            swiftSettings: strict
        ),
    ]
)
