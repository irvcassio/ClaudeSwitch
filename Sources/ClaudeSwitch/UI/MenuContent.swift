import ClaudeSwitchCore
import ClaudeSwitchUpdates
import SwiftUI

struct MenuContent: View {
    @Environment(SwitchController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            currentDestination
            Button(controller.toggleTitle) { Task { await controller.toggle() } }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(controller.isBusy || (controller.isOnAnthropic && controller.toggleTarget == nil))
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
            Text("CLI: Anthropic (your subscription)")
        case .profile(let profile):
            Text("CLI: \(profile.name) — \(profile.model)")
        case .unrecognised(let baseURL, let model):
            Text("CLI: an unsaved destination — \(model.isEmpty ? baseURL : model)")
        }
        Text(desktopLine)
        if controller.isBusy {
            Text("Checking the destination…")
        }
    }

    private var desktopLine: String {
        guard let desktop = controller.desktop else { return "Desktop: Claude.ai" }
        if desktop.managedByMDM { return "Desktop: set by a management profile" }
        if desktop.isOnGateway {
            return "Desktop: gateway (\(desktop.models.first ?? "no model")) — at next launch"
        }
        return "Desktop: Claude.ai"
    }

    @ViewBuilder private var destinationPicker: some View {
        Button {
            Task { await controller.switchToAnthropic() }
        } label: {
            Label("Anthropic (cloud)", systemImage: controller.isOnAnthropic ? "checkmark" : "cloud")
        }
        .disabled(controller.isBusy)

        if controller.profiles.isEmpty {
            Text("No destinations yet — add one in Settings")
        }

        ForEach(controller.profiles) { profile in
            Button {
                Task { await controller.switchTo(profile) }
            } label: {
                Label(profile.name + (profile.switchesDesktop ? " (CLI + Desktop)" : " (CLI)"),
                      systemImage: controller.activeProfile?.id == profile.id ? "checkmark" : symbol(for: profile.provider))
            }
            .disabled(controller.isBusy)
        }
    }

    private func symbol(for provider: Provider) -> String {
        switch provider {
        case .lmStudio, .ollama: "desktopcomputer"
        case .liteLLM, .custom: "server.rack"
        }
    }

    @ViewBuilder private var status: some View {
        if let profile = controller.activeProfile {
            switch controller.liveness {
            case .up?:
                Text(healthLine(profile))
            case .down(let reason)?:
                Text("⚠︎ Destination unreachable — \(reason)")
            case .degraded(let reason)?:
                Text("⚠︎ Destination degraded — \(reason)")
            case nil:
                Text("Destination not checked yet")
            }
        }

        if let profile = controller.activeProfile, profile.usesRelay {
            Text("Relay: " + controller.relayStatus(for: profile))
        }

        let set = controller.environment.rows.filter { $0.status == .set }.count
        let problems = controller.environment.rows.filter { [.mismatch, .missing, .stray].contains($0.status) }.count
        Text("Env: \(set) key\(set == 1 ? "" : "s") set" + (problems > 0 ? ", \(problems) need attention" : ""))

        if !controller.shellOverrides.isEmpty {
            Text("\(controller.shellOverrides.count) shell export\(controller.shellOverrides.count == 1 ? "" : "s") in your dotfiles")
        }

        if let note = controller.statusNote {
            Text(note)
        }
        if let error = controller.lastError {
            Text(error)
        }

        Button("Check Destination Now") { Task { await controller.recheck() } }
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

    private func healthLine(_ profile: Profile) -> String {
        var parts = ["Healthy"]
        if let probe = controller.probe, let latency = probe.latency {
            parts.append("\(GatewayProbe.milliseconds(latency)) ms")
        }
        if profile.modelLength > 0 {
            parts.append("\(profile.contextWindow.formatted()) / \(profile.modelLength.formatted()) ctx")
        }
        return parts.joined(separator: " · ")
    }
}
