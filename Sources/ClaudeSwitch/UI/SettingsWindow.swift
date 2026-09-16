import ClaudeSwitchCore
import ClaudeSwitchUpdates
import SwiftUI

/// Sidebar destinations. Diagnostics is a peer of the destinations, not a fallback for having
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
                Section("Destinations") {
                    if controller.profiles.isEmpty {
                        Text("No destinations yet. Add one with + below — LM Studio on this Mac, "
                             + "a LiteLLM proxy, or Ollama.")
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
                                Text(profile.model.isEmpty ? profile.provider.displayName : profile.model)
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
            .frame(minWidth: 230)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        ForEach(Provider.allCases) { provider in
                            Button(provider.displayName) {
                                selection = .gateway(controller.addProfile(provider: provider).id)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add a destination")
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
                    .help("Remove the selected destination")
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
        .frame(minWidth: 860, minHeight: 640)
        .onAppear {
            // Open on whichever destination is live, so the window answers "what am I on?" first.
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
    @State private var key = ""
    @State private var keyLoaded = false
    @State private var probe: GatewayProbe.Result?
    @State private var isChecking = false
    @State private var listing: DestinationDiscovery.Result?
    @State private var isDiscovering = false
    @State private var limitsNote: String?
    @State private var sameModelEverywhere: Bool

    init(profile: Profile) {
        _draft = State(initialValue: profile)
        _sameModelEverywhere = State(initialValue:
            [profile.haikuModel, profile.sonnetModel, profile.opusModel].allSatisfy { $0 == profile.model })
    }

    private var isDirty: Bool {
        controller.profiles.first { $0.id == draft.id } != draft
    }

    private var busy: Bool { isChecking || isDiscovering }

    var body: some View {
        Form {
            destinationSection
            modelSection
            limitsSection
            relaySection
            desktopSection
            environmentSection

            if !draft.staticWarnings.isEmpty {
                Section("Before you switch") {
                    ForEach(draft.staticWarnings) { WarningRow(warning: $0) }
                }
            }

            if let probe {
                Section("Last check") {
                    ProbeSummary(probe: probe)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { toolbar }
        .onAppear(perform: loadKey)
    }

    // MARK: Sections

    private var destinationSection: some View {
        Section("Destination") {
            TextField("Name", text: $draft.name)
            Picker("Server", selection: $draft.provider) {
                ForEach(Provider.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: draft.provider) { old, new in
                if draft.baseURL.isEmpty || draft.baseURL == old.defaultBaseURL {
                    draft.baseURL = new.defaultBaseURL
                }
                listing = nil
                draft.modelLength = 0
                limitsNote = nil
            }
            TextField("Base URL", text: $draft.baseURL,
                      prompt: Text(draft.provider.defaultBaseURL.isEmpty
                                   ? "http://proxy.example:4000" : draft.provider.defaultBaseURL))
                .autocorrectionDisabled()
            Text(draft.provider.baseURLHelp + " No trailing /v1.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Says nothing unless the certificate is actually untrusted — see `TrustRow`.
            TrustRow(baseURL: draft.baseURL, fingerprint: $draft.caAnchorFingerprint)

            if draft.provider.requiresKey {
                SecureField("Key", text: $key, prompt: Text("sk-…"))
                    .autocorrectionDisabled()
                Text("Kept in your login keychain. It is written to settings.json only while this "
                     + "destination is active, and removed when you switch back to Anthropic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Key", value: "None needed")
                Text("ClaudeSwitch sends the placeholder “\(draft.provider.placeholderToken ?? "")” as the "
                     + "token. Leaving it empty would make Claude Code send your Anthropic credential "
                     + "to this server instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelSection: some View {
        Section {
            HStack {
                Button(listing == nil ? "Discover Models" : "Discover Again") {
                    Task { await discover() }
                }
                .disabled(busy || draft.baseURL.isEmpty)
                if isDiscovering { ProgressView().controlSize(.small) }
                Spacer()
                if let listing {
                    Text("\(listing.selectableModels.count) usable of \(listing.models.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let listing, !listing.models.isEmpty {
                Picker("Model", selection: Binding(get: { draft.model }, set: { choose($0) })) {
                    if draft.model.isEmpty { Text("Choose…").tag("") }
                    if !draft.model.isEmpty, !listing.models.contains(where: { $0.id == draft.model }) {
                        Text("\(draft.model) — not served here").tag(draft.model)
                    }
                    ForEach(listing.models) { model in
                        Text(model.summary.isEmpty ? model.id : "\(model.id)  (\(model.summary))")
                            .tag(model.id)
                            .selectionDisabled(!model.isSelectable)
                    }
                }
                if let chosen = listing.models.first(where: { $0.id == draft.model }), let detail = chosen.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(listing.findings) { WarningRow(warning: $0) }
            } else {
                TextField("Model", text: Binding(get: { draft.model }, set: { choose($0, measure: false) }))
                if let listing {
                    ForEach(listing.findings) { WarningRow(warning: $0) }
                } else {
                    Text("Discover asks the server which models it can serve right now, and how much "
                         + "context each one really has.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Use this model for background work and every alias", isOn: $sameModelEverywhere)
                .onChange(of: sameModelEverywhere) { _, on in
                    if on { choose(draft.model, measure: false) }
                }
            if !sameModelEverywhere {
                aliasField("Haiku (titles, summaries, Explore)", text: $draft.haikuModel)
                aliasField("Sonnet", text: $draft.sonnetModel)
                aliasField("Opus", text: $draft.opusModel)
            }
            Picker("Effort level", selection: $draft.effortLevel) {
                ForEach(Profile.effortLevels, id: \.self) { Text($0).tag($0) }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Claude Code resolves background work through the haiku alias, not the main model. "
                 + "Left unmapped, sessions work but titles never appear.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func aliasField(_ label: String, text: Binding<String>) -> some View {
        if let listing, !listing.selectableModels.isEmpty {
            Picker(label, selection: text) {
                if !listing.selectableModels.contains(where: { $0.id == text.wrappedValue }) {
                    Text(text.wrappedValue.isEmpty ? "Choose…" : text.wrappedValue).tag(text.wrappedValue)
                }
                ForEach(listing.selectableModels) { Text($0.id).tag($0.id) }
            }
        } else {
            TextField(label, text: text)
        }
    }

    private var limitsSection: some View {
        Section {
            if draft.modelLength > 0 {
                LabeledContent("Server length", value: "\(draft.modelLength.formatted()) tokens")
            } else {
                TextField("Server length", value: $draft.modelLength, format: .number.grouping(.never),
                          prompt: Text("Discover reads this"))
            }
            TextField("Max output tokens", value: $draft.maxOutputTokens, format: .number.grouping(.never))
            TextField("Context window", value: $draft.contextWindow, format: .number.grouping(.never))
            HStack {
                Button("Use Recommended Limits") {
                    draft.adopt(LimitPlan.plan(modelLength: draft.modelLength,
                                               desiredMaxOutput: draft.maxOutputTokens))
                    limitsNote = nil
                }
                .disabled(draft.modelLength <= 0)
                if draft.modelLength > 0 {
                    Spacer()
                    let used = draft.contextWindow + draft.maxOutputTokens
                    Text("\(draft.contextWindow.formatted()) + \(draft.maxOutputTokens.formatted()) = "
                         + "\(used.formatted()) of \(draft.modelLength.formatted())")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(used > draft.modelLength ? .red : .secondary)
                }
            }
            if let limitsNote {
                Text(limitsNote).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Limits")
        } footer: {
            Text("The server stops at its length for prompt and reply together. Claude Code asks for the "
                 + "max output on every turn and only compacts near the context window — so the window "
                 + "must leave room for the output, or a long session hits the ceiling and hangs on "
                 + "retries. Reasoning counts towards max output; keep it generous.")
                .font(.caption)
        }
    }

    private var relaySection: some View {
        Section {
            Toggle("Route through the compatibility relay", isOn: Binding(
                get: { draft.usesRelay },
                set: { draft.relayPort = $0 ? controller.nextRelayPort(excluding: draft.id) : 0 }))
            if draft.usesRelay {
                TextField("Relay port", value: $draft.relayPort, format: .number.grouping(.never))
                if let saved = controller.profiles.first(where: { $0.id == draft.id }) {
                    LabeledContent("Status", value: controller.relayStatus(for: saved))
                }
            }
        } header: {
            Text("Compatibility relay")
        } footer: {
            Text("Claude Code now puts system messages inside the conversation, and vLLM's Anthropic "
                 + "endpoint — so a LiteLLM proxy in front of it — rejects them. With the relay on, Claude "
                 + "Code talks to ClaudeSwitch on 127.0.0.1, which folds those messages into the user turn "
                 + "and forwards everything else untouched. It also gives Claude Desktop the local address "
                 + "it requires. ClaudeSwitch must be running while relayed sessions are in use. Test "
                 + "Destination's “Request shape” check says whether the server still needs it.")
                .font(.caption)
        }
    }

    private var desktopSection: some View {
        Section {
            Toggle("Also switch Claude Desktop", isOn: $draft.switchesDesktop)
            if draft.switchesDesktop, let reason = DesktopGatewayStore.ineligibility(of: draft) {
                Text(reason).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Claude Desktop")
        } footer: {
            Text("The desktop ignores the base URL and key in settings.json — it sets its own for every "
                 + "session. Turned on, switching writes the desktop's own gateway configuration instead "
                 + "(the one Developer → Configure Third-Party Inference… edits) and opens it on that side "
                 + "at its next launch. The gateway side keeps its own conversations, and the desktop's "
                 + "sign-in screen offers both. It accepts HTTPS, or plain HTTP on this Mac only.")
                .font(.caption)
        }
    }

    private var environmentSection: some View {
        Section {
            let token = draft.effectiveToken(savedKey: key) ?? ""
            ForEach(draft.environment(authToken: token), id: \.key) { pair in
                LabeledContent {
                    Text(pair.key == "ANTHROPIC_AUTH_TOKEN" ? EnvironmentReport.mask(pair.value) : pair.value)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } label: {
                    HStack(spacing: 4) {
                        Text(pair.key).font(.system(.caption, design: .monospaced))
                        if EnvironmentReport.desktopOwnedKeys.contains(pair.key) {
                            Text("CLI only")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
        } header: {
            Text("Environment this writes")
        } footer: {
            Text("These go into the env block of ~/.claude/settings.json while this destination is "
                 + "active, and are all removed when you switch back. Keys marked CLI only are replaced "
                 + "by Claude Desktop in the sessions it hosts. Diagnostics shows what is set right now.")
                .font(.caption)
        }
    }

    private var toolbar: some View {
        HStack {
            Button("Test Destination") {
                Task {
                    isChecking = true
                    // A relayed draft is checked through its relay, which runs for saved settings.
                    if draft.usesRelay {
                        saveKey()
                        controller.update(draft)
                    }
                    probe = await GatewayProbe.run(profile: draft, authToken: key)
                    if let length = probe?.serverLength, draft.modelLength == 0 { draft.modelLength = length }
                    isChecking = false
                }
            }
            .disabled(busy || draft.baseURL.isEmpty || draft.model.isEmpty)

            if isChecking {
                ProgressView().controlSize(.small)
                Text("Sending test turns…").font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button("Revert") {
                if let original = controller.profiles.first(where: { $0.id == draft.id }) {
                    draft = original
                }
                loadKey()
            }
            .disabled(!isDirty)

            Button("Save") {
                saveKey()
                controller.update(draft)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isUsable)
        }
        .padding()
        .background(.bar)
    }

    // MARK: Actions

    private func choose(_ id: String, measure: Bool = true) {
        draft.model = id
        if sameModelEverywhere {
            draft.haikuModel = id
            draft.sonnetModel = id
            draft.opusModel = id
        }
        if measure, !id.isEmpty { Task { await readLimits() } }
    }

    private func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        saveKey()
        let result = await controller.discover(draft, key: key)
        listing = result
        if !result.selectableModels.contains(where: { $0.id == draft.model }),
           let first = result.selectableModels.first {
            choose(first.id, measure: false)
        }
        await readLimits()
    }

    /// Reads the chosen model's real ceiling and fits the limits inside it.
    private func readLimits() async {
        guard !draft.model.isEmpty else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        let model = draft.model
        let length = await controller.serverLength(draft, key: key, listing: listing)
        guard draft.model == model else { return }
        guard let length else {
            limitsNote = "Could not read the server's length for \(model). Enter it by hand — for vLLM "
                + "it is --max-model-len; for LM Studio, the context the model was loaded with."
            return
        }
        let listed = listing?.models.first { $0.id == model }
        let desired = draft.maxOutputTokens > 0 ? draft.maxOutputTokens : LimitPlan.defaultMaxOutputTokens
        draft.adopt(LimitPlan.plan(modelLength: length, desiredMaxOutput: desired,
                                   serverMaxOutput: listed?.serverMaxOutput))
        limitsNote = "Read \(length.formatted()) tokens from the server for \(model), and fitted the "
            + "window and output inside it."
    }

    private func loadKey() {
        key = KeychainStore.load(for: draft.id) ?? ""
        keyLoaded = true
    }

    private func saveKey() {
        guard keyLoaded else { return }
        if key.isEmpty {
            KeychainStore.delete(for: draft.id)
        } else {
            try? KeychainStore.save(key, for: draft.id)
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsPane: View {
    @Environment(SwitchController.self) private var controller

    var body: some View {
        Form {
            Section("Where turns go right now") {
                LabeledContent("CLI", value: destinationLabel)
                LabeledContent("Claude Desktop", value: desktopLabel)
                LabeledContent("Settings file", value: controller.settingsPath)
                Button("Show settings.json in Finder") { controller.revealSettingsFile() }
            }

            Section {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Key").bold()
                        Text("Wanted").bold()
                        Text("In settings.json").bold()
                        Text("Status").bold()
                    }
                    .font(.caption)
                    Divider()
                    ForEach(controller.environment.rows) { row in
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.key).font(.system(.caption, design: .monospaced))
                                if row.reach == .cliOnly {
                                    Text("CLI only").font(.caption2).foregroundStyle(.secondary)
                                }
                                ForEach(row.shellExports, id: \.self) { export in
                                    Text("also exported at \(export)").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Text(row.expected ?? "—").font(.system(.caption, design: .monospaced))
                            Text(row.inSettings ?? "not set").font(.system(.caption, design: .monospaced))
                                .foregroundStyle(row.inSettings == nil ? .secondary : .primary)
                            statusLabel(row.status)
                        }
                    }
                }
                .textSelection(.enabled)
            } header: {
                Text("Environment keys")
            } footer: {
                Text("“Wanted” is what the active destination writes; on Anthropic nothing should be set. "
                     + "Keys marked CLI only are replaced by Claude Desktop in the sessions it hosts. "
                     + "Keys are never shown in full.")
                    .font(.caption)
            }

            Section("Claude Desktop") {
                if let desktop = controller.desktop {
                    LabeledContent("Opens on", value: desktop.mode == .gateway ? "Gateway (third-party mode)"
                                   : desktop.mode == .claudeAI ? "Claude.ai" : "Claude.ai (never switched)")
                    LabeledContent("ClaudeSwitch configuration",
                                   value: desktop.entryID == nil ? "none"
                                   : desktop.entryApplied ? "applied" : "saved, not applied")
                    if let baseURL = desktop.baseURL {
                        LabeledContent("Gateway", value: baseURL)
                        LabeledContent("Models", value: desktop.models.joined(separator: ", "))
                        LabeledContent("Key on disk", value: desktop.hasKey ? "yes, while switched" : "no")
                    }
                    if desktop.managedByMDM {
                        Text("A management profile configures Claude Desktop on this Mac, and it overrides "
                             + "anything ClaudeSwitch writes.")
                            .foregroundStyle(.red)
                    }
                }
                LabeledContent("Configuration folder", value: controller.desktopConfigPath)
                LabeledContent("App", value: ClaudeDesktopApp.isRunning ? "Running" : "Not running")
                Text("Changes apply when the desktop next launches. If a switch does not show up, open "
                     + "Help → Troubleshooting → Enable Developer Mode, then Developer → Configure "
                     + "Third-Party Inference… — the ClaudeSwitch entry and any validation error appear "
                     + "there — and check ~/Library/Logs/Claude-3p/main.log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Relaunch Claude Desktop") { Task { await controller.relaunchDesktopApp() } }
                    .disabled(controller.isBusy)
            }

            Section("Top-level overrides") {
                if controller.topLevelOverrides.isEmpty {
                    Text(controller.hasStashedOverrides
                         ? "None in the file. Your originals are set aside and go back where they "
                           + "were when you switch to Anthropic."
                         : "None. No top-level key is contradicting the env block.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("These sit at the top level of settings.json and outrank the env block — "
                         + "`model` beats ANTHROPIC_MODEL and `effortLevel` beats "
                         + "CLAUDE_CODE_EFFORT_LEVEL. Switching to a destination sets them aside and "
                         + "restores them on the way back.")
                        .font(.callout)
                    ForEach(controller.topLevelOverrides.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                        LabeledContent(entry.key, value: entry.value)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            Section("Shell exports") {
                if controller.shellOverrides.isEmpty {
                    Text("None. Nothing in your dotfiles contradicts settings.json.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("settings.json wins over the shell, so these do nothing while a destination "
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

    @ViewBuilder
    private func statusLabel(_ status: EnvironmentReport.Row.Status) -> some View {
        switch status {
        case .set: Label("set", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unset: Label("unset", systemImage: "circle").foregroundStyle(.secondary)
        case .missing: Label("missing", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .mismatch: Label("differs", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .stray: Label("set, not by the active destination", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
    }

    private var destinationLabel: String {
        switch controller.mode {
        case .anthropic: "Anthropic (your subscription)"
        case .profile(let p): "\(p.name) — \(p.model) at \(p.baseURL)"
        case .unrecognised(let baseURL, let model): "Unsaved: \(baseURL) / \(model)"
        }
    }

    private var desktopLabel: String {
        guard let desktop = controller.desktop else { return "Claude.ai" }
        if desktop.managedByMDM { return "Set by a management profile" }
        return desktop.isOnGateway ? "Gateway at next launch — \(desktop.baseURL ?? "")" : "Claude.ai"
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
        LabeledContent("Verdict", value: probe.isHealthy ? "Ready to switch" : "Not ready")
            .foregroundStyle(probe.isHealthy ? .green : .red)
        ForEach(probe.steps) { step in
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.name).bold()
                    Text(step.detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon(step.state)).foregroundStyle(color(step.state))
            }
        }
        let cautions = probe.findings.filter { $0.severity == .caution }
        ForEach(cautions) { WarningRow(warning: $0) }
    }

    private func icon(_ state: GatewayProbe.Step.State) -> String {
        switch state {
        case .passed: "checkmark.circle.fill"
        case .warned: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        }
    }

    private func color(_ state: GatewayProbe.Step.State) -> Color {
        switch state {
        case .passed: .green
        case .warned: .orange
        case .failed: .red
        case .skipped: .secondary
        }
    }
}
