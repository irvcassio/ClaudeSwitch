import ClaudeSwitchCore
import SwiftUI

@main
struct ClaudeSwitchApp: App {
    @State private var controller = SwitchController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(controller)
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel(accessibilityLabel)
        }

        Window("ClaudeSwitch Settings", id: "settings") {
            SettingsWindow()
                .environment(controller)
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
