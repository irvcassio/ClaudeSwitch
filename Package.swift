// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeSwitch",
    platforms: [.macOS(.v15)],
    targets: [
        // Everything that touches the user's settings file lives here, with no UI, so it can
        // be tested directly. The app target is presentation only.
        .target(
            name: "ClaudeSwitchCore",
            path: "Sources/ClaudeSwitchCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ClaudeSwitch",
            dependencies: ["ClaudeSwitchCore"],
            path: "Sources/ClaudeSwitch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudeSwitchCoreTests",
            dependencies: ["ClaudeSwitchCore"],
            path: "Tests/ClaudeSwitchCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
