// swift-tools-version: 6.2
//
// 6.2 rather than 6.0 because `.v26` is not a platform SwiftPM 6.0 can name.
// Raising the floor therefore raises the toolchain floor with it.

import Foundation
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
    // with it verbatim; only the capture backend differs.
    //
    // The 26 floor across the board is a deliberate trade. The two APIs this
    // SDK is designed around -- RealityView's customPostProcessing and
    // NetworkConnection<QUIC> -- both arrived in the 26 release train, and
    // supporting anything older means carrying a second capture path and a
    // second transport path forever, each of which would need a device to test
    // and neither of which is the product. Everything here is unconditional as
    // a result: there is not one availability check in the SDK.
    //
    // macOS is on the same floor rather than a lower one because the package's
    // tests run there, so a lower macOS floor would reintroduce exactly the
    // gating this removes the moment shared code touches either API.
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26), .tvOS(.v26)],
    products: [
        .library(name: "MoqomKit", targets: ["MoqomKit"]),
        .library(name: "MoqomLoopback", targets: ["MoqomLoopback"]),
        // Exposed rather than kept internal because a relay implementer, a
        // fuzzer, or anyone diffing our bytes against another stack needs the
        // codec without the SDK on top of it.
        .library(name: "MoqomWire", targets: ["MoqomWire"]),
    ],
    targets: [
        .target(name: "MoqomCore", swiftSettings: strict),
        .target(name: "MoqomWire", dependencies: ["MoqomCore"], swiftSettings: strict),
        .target(
            name: "MoqomKit",
            dependencies: ["MoqomCore", "MoqomWire"],
            swiftSettings: strict
        ),
        .target(
            name: "MoqomLoopback",
            dependencies: ["MoqomCore", "MoqomKit"],
            swiftSettings: strict
        ),
        .testTarget(name: "MoqomCoreTests", dependencies: ["MoqomCore"], swiftSettings: strict),
        .testTarget(name: "MoqomWireTests", dependencies: ["MoqomWire"], swiftSettings: strict),
        // Helpers both direct-path suites share: tokens minted the way the
        // control plane mints them, and two endpoints establishing at once.
        .target(
            name: "MoqomDirectTesting",
            dependencies: ["MoqomCore", "MoqomKit"],
            path: "Tests/MoqomDirectTesting",
            swiftSettings: strict
        ),
        .testTarget(
            name: "MoqomKitTests",
            dependencies: ["MoqomKit", "MoqomLoopback", "MoqomWire", "MoqomDirectTesting"],
            swiftSettings: strict
        ),
    ]
)

// The Rust direct backend, from moqom-engine's moqom-direct-ffi.
//
// The xcframework is a build artefact of the sibling repository, not something
// this one carries, so the targets that link it exist only when asked for:
//
// - `Scripts/direct-ffi.sh` builds it and copies it to `Artifacts/`, which is
//   ignored by git. Its presence there turns the targets on, in SwiftPM and in
//   Xcode alike.
// - MOQOM_DIRECT_RUST=1 turns them on without a copy, linking
//   `../moqom-engine/target/MoqomDirectFFI.xcframework`, or the path in
//   MOQOM_DIRECT_FFI_XCFRAMEWORK (relative to this directory), which turns
//   them on by itself.
//
// An environment switch as well as a file check because the manifest is
// sandboxed and cannot see outside this directory, so it cannot notice the
// sibling build by itself. Without either, the package is what it was and
// `.networkFramework` is the only backend.
let environment = ProcessInfo.processInfo.environment
let copiedFFI = "Artifacts/MoqomDirectFFI.xcframework"
let directFFI: String? =
    if let path = environment["MOQOM_DIRECT_FFI_XCFRAMEWORK"] {
        path
    } else if FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + copiedFFI) {
        copiedFFI
    } else if environment["MOQOM_DIRECT_RUST"] == "1" {
        "../moqom-engine/target/MoqomDirectFFI.xcframework"
    } else {
        nil
    }

if let directFFI {
    package.products.append(.library(name: "MoqomDirectRust", targets: ["MoqomDirectRust"]))
    package.targets += [
        // SwiftPM wants a path relative to this directory; `..` is allowed.
        .binaryTarget(name: "MoqomDirectFFI", path: directFFI),
        // Compiles to an empty module where there is no slice (visionOS, tvOS):
        // everything in it is under `#if canImport(MoqomDirectFFI)`.
        .target(
            name: "MoqomDirectRust",
            dependencies: [
                "MoqomKit",
                .target(name: "MoqomDirectFFI", condition: .when(platforms: [.iOS, .macOS])),
            ],
            swiftSettings: strict,
            // What the Rust standard library and rustls reach for on Apple
            // platforms.
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration", .when(platforms: [.iOS, .macOS])),
                .linkedLibrary("resolv"),
            ]
        ),
        .testTarget(
            name: "MoqomDirectRustTests",
            dependencies: ["MoqomDirectRust", "MoqomKit", "MoqomCore", "MoqomLoopback", "MoqomDirectTesting"],
            swiftSettings: strict
        ),
    ]
}
