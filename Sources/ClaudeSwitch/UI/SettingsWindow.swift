import ClaudeSwitchCore
import ClaudeSwitchUpdates
import SwiftUI

/// Sidebar destinations. Diagnostics is a peer of the gateways, not a fallback for having
/// nothing selected.
private enum Destination: Hashable {
    case gateway(UUID)
    case diagnostics
    case updates
}

struct SettingsWindow: View {
    @Environment(SwitchController.self) private var controller
    @State private var selection: Destination? = .diagnostics

    private var selectedProfileID: UUID? {
        if case .gateway(let id) = selection { return id }
        return nil
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Gateways") {
                    if controller.profiles.isEmpty {
                        Text("No gateways yet. Add one with + below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(controller.profiles) { profile in
                        HStack {
                            Image(systemName: controller.activeProfile?.id == profile.id
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(controller.activeProfile?.id == profile.id
                                                 ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(profile.name)
                                Text(profile.baseURL.isEmpty ? "No address yet" : profile.baseURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(Destination.gateway(profile.id))
                    }
                }

                Section {
                    Label("Diagnostics", systemImage: "stethoscope")
                        .tag(Destination.diagnostics)
                    Label("Updates", systemImage: "arrow.down.circle")
                        .tag(Destination.updates)
                }
            }
            .frame(minWidth: 220)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        selection = .gateway(controller.addProfile().id)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add a gateway")
                    Button {
                        guard let id = selectedProfileID,
                              let profile = controller.profiles.first(where: { $0.id == id })
                        else { return }
                        Task {
                            await controller.deleteProfile(profile)
                            selection = controller.profiles.first.map { Destination.gateway($0.id) }
                                ?? .diagnostics
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedProfileID == nil)
                    .help("Remove the selected gateway")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
            if let id = selectedProfileID,
               let index = controller.profiles.firstIndex(where: { $0.id == id }) {
                ProfileEditor(profile: controller.profiles[index])
                    .id(id)
            } else if selection == .updates {
                UpdatesSettingsView()
            } else {
                DiagnosticsPane()
            }
        }
        .frame(minWidth: 780, minHeight: 580)
        .onAppear {
            // Open on whichever gateway is live, so the window answers "what am I on?" first.
            if let active = controller.activeProfile {
                selection = .gateway(active.id)
            }
        }
    }
}

// MARK: - Profile editor

private struct ProfileEditor: View {
    @Environment(SwitchController.self) private var controller

    @State private var draft: Profile
    @State private var token = ""
    @State private var tokenLoaded = false
    @State private var probe: GatewayProbe.Result?
    @State private var isChecking = false

    init(profile: Profile) {
        _draft = State(initialValue: profile)
    }

    private var isDirty: Bool {
        controller.profiles.first { $0.id == draft.id } != draft
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $draft.name)
                TextField("Base URL", text: $draft.baseURL, prompt: Text("http://gateway.example:4000"))
                    .autocorrectionDisabled()
                Text("Without a trailing /v1 — Claude Code appends the Anthropic paths itself. "
                     + "Port 4000 is the gateway; 8001 is vLLM and has no /v1/messages route.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Key") {
                SecureField("LiteLLM virtual key", text: $token, prompt: Text("sk-…"))
                    .autocorrectionDisabled()
                Text("Kept in your login keychain. It is written into settings.json only while "
                     + "this gateway is active, and removed when you switch back to Anthropic. "
                     + "The gateway is plain HTTP, so treat the key as low-assurance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Models") {
                TextField("Model", text: $draft.model)
                TextField("Haiku alias", text: $draft.haikuModel)
                TextField("Sonnet alias", text: $draft.sonnetModel)
                TextField("Opus alias", text: $draft.opusModel)
                Button("Copy model to all aliases") {
                    draft.haikuModel = draft.model
                    draft.sonnetModel = draft.model
                    draft.opusModel = draft.model
                }
                Text("Background work — conversation titles and summaries — resolves the haiku "
                     + "alias, not the model. Left unmapped, sessions work but titles never appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Limits") {
                Picker("Effort level", selection: $draft.effortLevel) {
                    ForEach(Profile.effortLevels, id: \.self) { level in
                        Text(Profile.qwenSafeEffortLevels.contains(level) ? level : "\(level) — 500s on Qwen3.8")
                            .tag(level)
                    }
                }
                TextField("Context window", value: $draft.contextWindow,
                          format: .number.grouping(.never))
                TextField("Max output tokens", value: $draft.maxOutputTokens,
                          format: .number.grouping(.never))
                Text("Set the context window to the same number the model server was started "
                     + "with. Guessing it makes compaction fire early or overflow the server. "
                     + "The output ceiling is the only guard against a reasoning model "
                     + "spiralling in its thinking block.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Options") {
                Toggle("Suppress nonessential traffic", isOn: $draft.disableNonessentialTraffic)
                Toggle("Let /model list what the gateway publishes", isOn: $draft.enableGatewayModelDiscovery)
            }

            if !draft.staticWarnings.isEmpty {
                Section("Before you switch") {
                    ForEach(draft.staticWarnings) { warning in
                        WarningRow(warning: warning)
                    }
                }
            }

            if let probe {
                Section("Last check") {
                    ProbeSummary(probe: probe)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Test Connection") {
                    Task {
                        isChecking = true
                        saveToken()
                        controller.update(draft)
                        probe = await controller.check(draft)
                        isChecking = false
                    }
                }
                .disabled(isChecking || !draft.isUsable)

                if isChecking { ProgressView().controlSize(.small) }

                Spacer()

                Button("Revert") {
                    if let original = controller.profiles.first(where: { $0.id == draft.id }) {
                        draft = original
                    }
                    loadToken()
                }
                .disabled(!isDirty)

                Button("Save") {
                    saveToken()
                    controller.update(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isUsable)
            }
            .padding()
            .background(.bar)
        }
        .onAppear(perform: loadToken)
    }

    private func loadToken() {
        token = KeychainStore.load(for: draft.id) ?? ""
        tokenLoaded = true
    }

    private func saveToken() {
        guard tokenLoaded else { return }
        if token.isEmpty {
            KeychainStore.delete(for: draft.id)
        } else {
            try? KeychainStore.save(token, for: draft.id)
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsPane: View {
    @Environment(SwitchController.self) private var controller

    var body: some View {
        Form {
            Section("Where turns go right now") {
                LabeledContent("Destination", value: destinationLabel)
                LabeledContent("Settings file", value: controller.settingsPath)
                Button("Show settings.json in Finder") { controller.revealSettingsFile() }
            }

            Section("Shell overrides") {
                if controller.shellOverrides.isEmpty {
                    Text("None. Nothing in your dotfiles contradicts settings.json.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("settings.json wins over the shell, so these do nothing while a gateway "
                         + "is active. But they become live again the moment you switch back to "
                         + "Anthropic — comment them out if you do not want that.")
                        .font(.callout)
                    ForEach(controller.shellOverrides) { override in
                        LabeledContent(override.variable, value: "~/\(override.file):\(override.line)")
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            Section("Running sessions") {
                Text(controller.runningCLISessions == 0
                     ? "No CLI sessions running."
                     : "\(controller.runningCLISessions) CLI session\(controller.runningCLISessions == 1 ? "" : "s") running. "
                       + "Claude Code reads settings at launch, so a switch does not reach them — "
                       + "start a new session.")
                LabeledContent("Claude desktop app",
                               value: ClaudeDesktopApp.isRunning ? "Running" : "Not running")
                Button("Relaunch Claude Desktop") { Task { await controller.relaunchDesktopApp() } }
                    .disabled(controller.isBusy)
            }

            Section("Backup") {
                if controller.hasBackup {
                    Text("A copy of your settings from before ClaudeSwitch first edited them. "
                         + "It is never overwritten.")
                        .font(.callout)
                    Text(controller.backupPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("No backup yet — ClaudeSwitch has not edited your settings. It will "
                         + "keep one copy of the original the first time you switch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = controller.lastError {
                Section("Last error") {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
        .onAppear { controller.refresh() }
    }

    private var destinationLabel: String {
        switch controller.mode {
        case .anthropic: "Anthropic (your subscription)"
        case .profile(let p): "\(p.name) — \(p.baseURL)"
        case .unrecognised(let baseURL, let model): "Unsaved: \(baseURL) / \(model)"
        }
    }
}

// MARK: - Shared rows

private struct WarningRow: View {
    let warning: Warning

    var body: some View {
        Label {
            Text(warning.message)
        } icon: {
            Image(systemName: warning.severity == .blocking
                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(warning.severity == .blocking ? .red : .orange)
        }
        .font(.callout)
    }
}

private struct ProbeSummary: View {
    let probe: GatewayProbe.Result

    var body: some View {
        LabeledContent("Reachable", value: probe.reachable ? "yes" : "no")
        LabeledContent("Anthropic route (/v1/messages)", value: probe.messagesRouteOK ? "answers" : "no")
        // The row that matters: Claude Code only ever streams, and this is the half that breaks
        // on its own while the row above stays green.
        LabeledContent("Streamed replies (SSE)",
                       value: probe.streamingRouteOK ? "well-formed"
                            : probe.messagesRouteOK ? "malformed" : "not checked")
        if let latency = probe.latency {
            let ms = Int(latency.components.seconds) * 1000
                + Int(Double(latency.components.attoseconds) / 1e15)
            LabeledContent("Round trip", value: "\(ms) ms")
        }
        if !probe.publishedModels.isEmpty {
            LabeledContent("Published models") {
                VStack(alignment: .trailing) {
                    ForEach(probe.publishedModels, id: \.self) { id in
                        Text(id).font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
        ForEach(probe.findings) { WarningRow(warning: $0) }
    }
}
