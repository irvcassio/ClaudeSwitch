import ClaudeSwitchCore
import ClaudeSwitchUpdates
import SwiftUI

@main
struct ClaudeSwitchApp: App {
    // No default value: the initialiser below needs the same instance it hands
    // to the updater's busy gate, and a default expression would build a second.
    @State private var controller: SwitchController
    // Sparkle's delegate is an NSObject that publishes with @Published, so the
    // updater stays an ObservableObject and is injected with .environmentObject
    // even though everything else here uses Observation.
    @StateObject private var updater = UpdaterService.shared

    init() {
        let controller = SwitchController()
        _controller = State(initialValue: controller)

        let updater = UpdaterService.shared
        // The only moment installing would be wrong: a switch is mid-flight, so
        // settings.json is being rewritten and the Claude desktop app may be
        // part-way through a relaunch.
        updater.busyReasonProvider = { [weak controller] in
            controller?.isBusy == true ? "a gateway switch is in progress" : nil
        }
        updater.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(controller)
                .environmentObject(updater)
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel(accessibilityLabel)
        }

        Window("ClaudeSwitch Settings", id: "settings") {
            SettingsWindow()
                .environment(controller)
                .environmentObject(updater)
        }
        .windowResizability(.contentMinSize)
    }

    /// The icon carries the state, so the destination is readable without opening the menu.
    private var menuBarSymbol: String {
        switch controller.mode {
        case .anthropic: "cloud"
        case .profile: "server.rack"
        case .unrecognised: "questionmark.circle"
        }
    }

    private var accessibilityLabel: String {
        switch controller.mode {
        case .anthropic: "Claude Code is on Anthropic"
        case .profile(let profile): "Claude Code is on \(profile.name)"
        case .unrecognised: "Claude Code is on an unsaved destination"
        }
    }
}
