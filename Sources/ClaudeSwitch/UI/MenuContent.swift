import ClaudeSwitchCore
import ClaudeSwitchUpdates
import SwiftUI

struct MenuContent: View {
    @Environment(SwitchController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            currentDestination
            Divider()
            destinationPicker
            Divider()
            status
            Divider()
            actions
        }
    }

    // MARK: - Sections

    @ViewBuilder private var currentDestination: some View {
        switch controller.mode {
        case .anthropic:
            Text("On Anthropic (your subscription)")
        case .profile(let profile):
            Text("On \(profile.name)")
        case .unrecognised(let baseURL, let model):
            Text("On an unsaved destination — \(model.isEmpty ? baseURL : model)")
        }
    }

    @ViewBuilder private var destinationPicker: some View {
        Button {
            Task { await controller.switchToAnthropic() }
        } label: {
            Label("Anthropic (cloud)", systemImage: controller.isOnAnthropic ? "checkmark" : "cloud")
        }
        .disabled(controller.isBusy)

        ForEach(controller.profiles) { profile in
            Button {
                Task { await controller.switchTo(profile) }
            } label: {
                Label(profile.name,
                      systemImage: controller.activeProfile?.id == profile.id ? "checkmark" : "server.rack")
            }
            .disabled(controller.isBusy)
        }
    }

    @ViewBuilder private var status: some View {
        if let probe = controller.probe, controller.activeProfile != nil {
            if probe.isHealthy {
                Text(healthLine(probe))
            } else {
                Text("Gateway check failed")
            }
        }

        if !controller.shellOverrides.isEmpty {
            Text("\(controller.shellOverrides.count) shell override\(controller.shellOverrides.count == 1 ? "" : "s") in your dotfiles")
        }

        if let note = controller.statusNote {
            Text(note)
        }
        if let error = controller.lastError {
            Text(error)
        }

        Button("Check Now") { Task { await controller.recheck() } }
            .disabled(controller.isBusy || controller.activeProfile == nil)
    }

    @ViewBuilder private var actions: some View {
        Button("Relaunch Claude Desktop") { Task { await controller.relaunchDesktopApp() } }
            .disabled(controller.isBusy)

        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        UpdateMenuItems()

        Divider()

        Button("Quit ClaudeSwitch") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func healthLine(_ probe: GatewayProbe.Result) -> String {
        var parts = ["Healthy"]
        if let latency = probe.latency {
            let ms = Int(Double(latency.components.attoseconds) / 1e15)
                + Int(latency.components.seconds) * 1000
            parts.append("\(ms) ms")
        }
        if !probe.publishedModels.isEmpty {
            parts.append("\(probe.publishedModels.count) models")
        }
        return parts.joined(separator: " · ")
    }
}
