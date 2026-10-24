// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rimlight",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic: beat detection, clocks, lyrics, palette, geometry, settings, CLI parsing. No AppKit.
        .target(name: "RimlightCore", path: "Sources/RimlightCore"),
        // The menu bar app: audio tap, Spotify bridge, Metal overlay, menu, CLI.
        .executableTarget(
            name: "Rimlight",
            dependencies: ["RimlightCore"],
            path: "Sources/Rimlight"
        ),
        .testTarget(name: "RimlightCoreTests", dependencies: ["RimlightCore"], path: "Tests/RimlightCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
