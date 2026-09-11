// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeSwitch",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned to a minor range, the same way Doppo Terminal pins it: Sparkle's
        // minor releases have changed delegate behaviour before, and the update
        // path is the one thing that cannot be fixed by shipping an update.
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.9.0")),
    ],
    targets: [
        // Everything that touches the user's settings file lives here, with no UI, so it can
        // be tested directly. The app target is presentation only.
        .target(
            name: "ClaudeSwitchCore",
            path: "Sources/ClaudeSwitchCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Sparkle is quarantined in its own target so ClaudeSwitchCore — and its
        // tests — never link a framework that expects to live in a packaged .app.
        .target(
            name: "ClaudeSwitchUpdates",
            dependencies: [
                "ClaudeSwitchCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ClaudeSwitchUpdates",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ClaudeSwitch",
            dependencies: ["ClaudeSwitchCore", "ClaudeSwitchUpdates"],
            path: "Sources/ClaudeSwitch",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle ships as an XCFramework that build-dmg.sh copies into
            // Contents/Frameworks. Without this rpath the packaged app launches
            // straight into a dyld failure, while `swift run` works fine.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "ClaudeSwitchCoreTests",
            dependencies: ["ClaudeSwitchCore"],
            path: "Tests/ClaudeSwitchCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
