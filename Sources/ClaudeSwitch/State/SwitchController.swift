import ClaudeSwitchCore
import Foundation
import Observation
import SwiftUI

/// The app's single source of truth: which destination Claude Code is pointed at, and whether
/// that destination actually works.
///
/// There are two Claude Codes to move and they are moved differently. The CLI reads the `env`
/// block of `~/.claude/settings.json`. Claude Desktop ignores that block for the base URL and
/// key — it sets those itself for every session it hosts — so it is moved through its own
/// third-party configuration instead, and only when the destination asks for it.
@MainActor
@Observable
final class SwitchController {
    /// Where the CLI is pointed right now, as read from disk rather than remembered.
    enum Mode: Equatable {
        case anthropic
        case profile(Profile)
        /// The file has managed keys that match no saved profile — edited by hand, or a profile
        /// was deleted while active. Never silently claim one or the other.
        case unrecognised(baseURL: String, model: String)
    }

    var profiles: [Profile] = []
    private(set) var mode: Mode = .anthropic
    private(set) var probe: GatewayProbe.Result?
    private(set) var liveness: GatewayProbe.Liveness?
    private(set) var isBusy = false
    var lastError: String?
    var statusNote: String?

    private(set) var shellOverrides: [Diagnostics.ShellOverride] = []
    private(set) var runningCLISessions = 0
    /// Top-level `model` / `effortLevel` still sitting in settings.json, where they outrank the
    /// managed env block. Should be empty on a gateway — anything here is beating the switch.
    private(set) var topLevelOverrides: [String: String] = [:]
    private(set) var environment = EnvironmentReport(rows: [])
    private(set) var desktop: DesktopGatewayStore.State?

    private let store = ClaudeSettingsStore.userSettings
    private let desktopStore = DesktopGatewayStore.user
    private let profilesURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/ClaudeSwitch/profiles.json")
    private var livenessTask: Task<Void, Never>?
    /// One relay per destination that routes through one. They keep running across switches, so
    /// a CLI session started on a relayed destination keeps working after the menu moves on.
    private var relays: [UUID: CompatibilityRelay] = [:]
    private(set) var relayErrors: [UUID: String] = [:]

    /// The destination ⌘T returns to. Remembered across launches.
    private var lastProfileID: String {
        get { UserDefaults.standard.string(forKey: "lastProfileID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastProfileID") }
    }

    var settingsPath: String { store.url.path }
    var backupPath: String { store.backupURL.path }
    var hasBackup: Bool { FileManager.default.fileExists(atPath: store.backupURL.path) }
    var desktopConfigPath: String { desktopStore.root.path }

    init() {
        loadProfiles()
        syncRelays()
        refresh()
        startLivenessTimer()
    }

    var activeProfile: Profile? {
        if case .profile(let p) = mode { return p }
        return nil
    }

    var isOnAnthropic: Bool { mode == .anthropic }

    /// What ⌘T switches to: back to Anthropic from anywhere, or to the destination used last.
    var toggleTarget: Profile? {
        guard isOnAnthropic else { return nil }
        return profiles.first { $0.id.uuidString == lastProfileID } ?? profiles.first
    }

    var toggleTitle: String {
        if !isOnAnthropic { return "Switch to Anthropic" }
        if let target = toggleTarget { return "Switch to \(target.name)" }
        return "Switch (no destinations yet)"
    }

    // MARK: - Reading current state

    /// Re-reads everything from disk. Cheap, and the only honest way to answer "which am I on?" —
    /// the files can change under us from an editor or another tool.
    func refresh() {
        var managed: [String: String] = [:]
        do {
            managed = try store.readManagedEnvironment()
            if let baseURL = managed["ANTHROPIC_BASE_URL"], !baseURL.isEmpty {
                let model = managed["ANTHROPIC_MODEL"] ?? ""
                if let match = profiles.first(where: { $0.clientBaseURL == baseURL && $0.model == model }) {
                    if activeProfile?.id != match.id { liveness = nil }
                    mode = .profile(match)
                } else {
                    mode = .unrecognised(baseURL: baseURL, model: model)
                }
            } else {
                mode = .anthropic
                probe = nil
                liveness = nil
            }
            lastError = nil
        } catch {
            mode = .anthropic
            lastError = "Could not read \(store.url.path): \(error.localizedDescription)"
        }
        refreshDiagnostics(managed: managed)
    }

    private func refreshDiagnostics(managed: [String: String]) {
        shellOverrides = Diagnostics.shellOverrides()
        runningCLISessions = Diagnostics.runningCLISessionCount()
        topLevelOverrides = (try? store.readTopLevelOverrides()) ?? [:]
        desktop = desktopStore.state()
        let profile = activeProfile
        environment = EnvironmentReport.build(
            profile: profile,
            token: profile.flatMap { $0.effectiveToken(savedKey: KeychainStore.load(for: $0.id)) },
            managed: managed,
            unmanaged: (try? store.readUnmanagedEnvironment()) ?? [:],
            shell: shellOverrides,
            foreignCABundle: TLSTrust.foreignBundle())
    }

    /// Whether the originals are parked, waiting to be put back on the way to Anthropic.
    var hasStashedOverrides: Bool {
        FileManager.default.fileExists(atPath: store.overridesStashURL.path)
    }

    // MARK: - Switching

    func toggle() async {
        if isOnAnthropic {
            guard let target = toggleTarget else {
                lastError = "No destinations yet. Add one in Settings."
                return
            }
            await switchTo(target)
        } else {
            await switchToAnthropic()
        }
    }

    func switchTo(_ profile: Profile) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        lastError = nil
        statusNote = nil

        guard profile.isUsable else {
            lastError = "Did not switch — fix these first:\n" + profile.staticWarnings
                .filter { $0.severity == .blocking }
                .map { "• " + $0.message }
                .joined(separator: "\n")
            return
        }
        guard let token = profile.effectiveToken(savedKey: KeychainStore.load(for: profile.id)) else {
            lastError = "No key saved for “\(profile.name)”. Add one in Settings — "
                + "\(profile.provider.displayName) answers 401 without it."
            return
        }

        if profile.usesRelay, let problem = relayProblem(for: profile) {
            lastError = "Did not switch — the compatibility relay for \(profile.name) is not running: \(problem)"
            return
        }

        // Verify before writing. Switching into a broken destination means the failure shows up
        // as a mystery error — or a hang — on the next turn, in a session already started.
        let result = await GatewayProbe.run(profile: profile, authToken: token)
        probe = result
        guard result.isHealthy else {
            lastError = "Did not switch — \(profile.name) failed its check. Your settings are "
                + "untouched.\n"
                + result.findings.filter { $0.severity == .blocking }
                    .map { "• " + $0.message }.joined(separator: "\n")
            return
        }

        do {
            // Read them before the write, which is what removes them.
            let setAside = (try? store.readTopLevelOverrides()) ?? [:]
            try store.apply(profile: profile, authToken: token)
            // After the write, which is what records the foreign bundle — the rebuild reads that
            // record. A user who set NODE_EXTRA_CA_CERTS after trusting the gateway's CA would
            // otherwise be on a bundle.pem built before their own bundle existed.
            try? TLSTrust.rebuildBundle()
            lastProfileID = profile.id.uuidString
            liveness = .up

            var notes = [cliNote()]
            if let foreign = TLSTrust.foreignBundle(), profile.caAnchorFingerprint != nil {
                notes.append(foreign.isUsable
                    ? "Your own NODE_EXTRA_CA_CERTS (\(foreign.configuredPath)) is kept: its "
                        + "\(foreign.certificateCount) certificate"
                        + (foreign.certificateCount == 1 ? " is" : "s are")
                        + " merged into the bundle Claude Code reads, and the original value goes "
                        + "back when you return to Anthropic."
                    : "Your own NODE_EXTRA_CA_CERTS is remembered and will be put back, but "
                        + "nothing could be merged from it: "
                        + (foreign.problem ?? "it holds no certificates."))
            }
            if !setAside.isEmpty {
                notes.append("Set aside \(setAside.keys.sorted().joined(separator: " and "))"
                    + " from the top level of settings.json — "
                    + (setAside.count == 1 ? "it outranks" : "they outrank")
                    + " the env block. Put back when you return to Anthropic.")
            }
            notes.append(moveDesktop(to: profile, token: token))
            refresh()
            statusNote = notes.joined(separator: "\n\n")
        } catch {
            lastError = error.localizedDescription
            refresh()
        }
    }

    func switchToAnthropic() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        lastError = nil
        statusNote = nil
        do {
            // Read before the clear, which is what consumes the record.
            let restored = store.loadForeignCAStash()
            try store.clearManagedEnvironment()
            var notes = [cliNote()]
            if let restored {
                notes.append("Put NODE_EXTRA_CA_CERTS back to \(restored.path) — the value you "
                    + "had before switching.")
            }
            if desktop?.isOnGateway == true {
                do {
                    try desktopStore.deactivate()
                    notes.append("Claude Desktop will open on Claude.ai at its next launch — relaunch it to switch now.")
                } catch {
                    notes.append("Claude Desktop is still set to the gateway: \(error.localizedDescription)")
                }
            }
            refresh()
            if !shellOverrides.isEmpty {
                notes.append("Heads up: \(shellOverrides.count) shell export"
                    + (shellOverrides.count == 1 ? "" : "s")
                    + " can now take effect again, because settings.json no longer overrides them. "
                    + "See Diagnostics.")
            }
            statusNote = notes.joined(separator: "\n\n")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Moves the desktop too, when the destination asks for it. A failure here does not undo the
    /// CLI switch — the two are independent, and the note says which one moved.
    private func moveDesktop(to profile: Profile, token: String) -> String {
        guard profile.switchesDesktop else {
            if desktop?.isOnGateway == true {
                try? desktopStore.deactivate()
                return "Claude Desktop stays on Claude.ai (this destination is CLI-only); its previous "
                    + "gateway setting was cleared. Relaunch it if it is running on the gateway."
            }
            return "Claude Desktop stays on Claude.ai — this destination switches the CLI only."
        }
        do {
            try desktopStore.activate(profile: profile, token: token)
            return "Claude Desktop will open on \(profile.name) at its next launch — relaunch it to "
                + "switch now. The gateway side keeps its own conversations, separate from Claude.ai's."
        } catch {
            return "The CLI switched, but Claude Desktop did not: \(error.localizedDescription)"
        }
    }

    /// Claude Code reads settings at launch, so nothing already running has moved.
    private func cliNote() -> String {
        let sessions = Diagnostics.runningCLISessionCount()
        var note = "The CLI picks this up in new sessions."
        if sessions > 0 {
            note += " \(sessions) running session" + (sessions == 1 ? " is" : "s are")
                + " still on the old destination."
        }
        return note
    }

    func relaunchDesktopApp() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await ClaudeDesktopApp.relaunch()
            statusNote = "Relaunched the Claude desktop app."
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Checking

    func recheck() async {
        guard let profile = activeProfile else {
            probe = nil
            refresh()
            return
        }
        isBusy = true
        defer { isBusy = false }
        probe = await GatewayProbe.run(profile: profile, authToken: KeychainStore.load(for: profile.id))
        liveness = probe?.isHealthy == true ? .up : .degraded("failed its last check")
    }

    func check(_ profile: Profile) async -> GatewayProbe.Result {
        await GatewayProbe.run(profile: profile, authToken: KeychainStore.load(for: profile.id))
    }

    func discover(_ profile: Profile, key: String?) async -> DestinationDiscovery.Result {
        await DestinationDiscovery.discover(provider: profile.provider, baseURL: profile.baseURL,
                                            token: profile.effectiveToken(savedKey: key))
    }

    func serverLength(_ profile: Profile, key: String?, listing: DestinationDiscovery.Result?) async -> Int? {
        await DestinationDiscovery.serverLength(provider: profile.provider, baseURL: profile.baseURL,
                                                token: profile.effectiveToken(savedKey: key),
                                                model: profile.model, listing: listing)
    }

    /// A cheap, generation-free check of the active destination, so the menu can say when a
    /// server went away or a model was unloaded before the next turn finds out.
    private func startLivenessTimer() {
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateLiveness()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func updateLiveness() async {
        guard let profile = activeProfile else { return }
        let state = await GatewayProbe.liveness(profile: profile, authToken: KeychainStore.load(for: profile.id))
        if activeProfile?.id == profile.id { liveness = state }
    }

    // MARK: - Relays

    /// Starts a relay for each destination that asks for one, and stops the rest. A relay whose
    /// port or server changed is replaced.
    func syncRelays() {
        let wanted = Dictionary(uniqueKeysWithValues: profiles.filter(\.usesRelay).map { ($0.id, $0) })
        for (id, relay) in relays {
            guard let profile = wanted[id], relay.port == UInt16(profile.relayPort),
                  relay.upstream.absoluteString == profile.baseURL
            else {
                relay.stop()
                relays[id] = nil
                continue
            }
        }
        relayErrors = [:]
        for (id, profile) in wanted where relays[id] == nil {
            guard let upstream = URL(string: profile.baseURL), upstream.host != nil,
                  let port = UInt16(exactly: profile.relayPort)
            else {
                relayErrors[id] = "the server address is not a valid URL"
                continue
            }
            let relay = CompatibilityRelay(port: port, upstream: upstream)
            do {
                try relay.startAndWait()
                relays[id] = relay
            } catch {
                relayErrors[id] = error.localizedDescription
            }
        }
    }

    func relayProblem(for profile: Profile) -> String? {
        if let error = relayErrors[profile.id] { return error }
        guard let relay = relays[profile.id] else { return "not started" }
        if case .failed(let message) = relay.state { return message }
        return relay.state == .running ? nil : "stopped"
    }

    func relayStatus(for profile: Profile) -> String {
        guard profile.usesRelay else { return "Off — Claude Code talks to the server directly" }
        if let problem = relayProblem(for: profile) { return "Not running — \(problem)" }
        let folded = relays[profile.id]?.foldedRequests ?? 0
        return "Running on 127.0.0.1:\(profile.relayPort) → \(profile.baseURL)"
            + (folded > 0 ? " · \(folded) request\(folded == 1 ? "" : "s") fixed" : "")
    }

    /// A free relay port no other destination uses.
    func nextRelayPort(excluding id: UUID? = nil) -> Int {
        let used = Set(profiles.filter { $0.id != id }.map(\.relayPort))
        var port = Profile.firstRelayPort
        while used.contains(port) { port += 1 }
        return port
    }

    // MARK: - Profile persistence

    func loadProfiles() {
        // A fresh install has no destinations. ClaudeSwitch does not know about anyone's network,
        // so it must not invent one — the user adds one with the + button.
        guard let data = try? Data(contentsOf: profilesURL),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data)
        else {
            profiles = []
            return
        }
        profiles = decoded
    }

    func saveProfiles() {
        do {
            try FileManager.default.createDirectory(at: profilesURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: profilesURL, options: .atomic)
        } catch {
            lastError = "Could not save destinations: \(error.localizedDescription)"
        }
        syncRelays()
        // A rename or a changed base URL changes what "active" means; re-derive it.
        refresh()
    }

    func addProfile(provider: Provider) -> Profile {
        let name = switch provider {
        case .lmStudio: "Qwen — LM Studio"
        case .liteLLM: "Qwen — LiteLLM"
        case .ollama: "Qwen — Ollama"
        case .custom: "New destination"
        }
        var new = Profile.blank(name: name, provider: provider)
        // A LiteLLM proxy in front of vLLM rejects what Claude Code 2.1.200 sends until the proxy
        // is fixed, so new proxy destinations start with the relay on. The probe says when it can
        // be turned off.
        if provider == .liteLLM { new.relayPort = nextRelayPort() }
        profiles.append(new)
        saveProfiles()
        return new
    }

    /// Deleting the active profile would leave the file pointed somewhere with no way back in
    /// the UI, so this returns to Anthropic first.
    func deleteProfile(_ profile: Profile) async {
        if activeProfile?.id == profile.id {
            await switchToAnthropic()
        }
        KeychainStore.delete(for: profile.id)
        profiles.removeAll { $0.id == profile.id }
        saveProfiles()
    }

    func update(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let wasActive = activeProfile?.id == profile.id
        profiles[index] = profile
        saveProfiles()

        // An edit to the live profile has to reach the files, or the menu and the files disagree.
        guard wasActive, profile.isUsable,
              let token = profile.effectiveToken(savedKey: KeychainStore.load(for: profile.id))
        else { return }
        do {
            try store.apply(profile: profile, authToken: token)
            try? TLSTrust.rebuildBundle()
            let desktopNote = moveDesktop(to: profile, token: token)
            refresh()
            statusNote = "Updated the live configuration. " + cliNote() + "\n\n" + desktopNote
        } catch {
            lastError = error.localizedDescription
        }
    }

    func revealSettingsFile() {
        NSWorkspace.shared.selectFile(store.url.path,
                                      inFileViewerRootedAtPath: store.url.deletingLastPathComponent().path)
    }
}
