import ClaudeSwitchCore
import Foundation
import Observation
import SwiftUI

/// The app's single source of truth: which destination Claude Code is pointed at, and whether
/// that destination actually works.
@MainActor
@Observable
final class SwitchController {
    /// Where Claude Code is pointed right now, as read from disk rather than remembered.
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
    private(set) var isBusy = false
    var lastError: String?
    var statusNote: String?

    private(set) var shellOverrides: [Diagnostics.ShellOverride] = []
    private(set) var runningCLISessions = 0

    private let store = ClaudeSettingsStore.userSettings
    private let profilesURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/ClaudeSwitch/profiles.json")

    var settingsPath: String { store.url.path }
    var backupPath: String { store.backupURL.path }
    var hasBackup: Bool { FileManager.default.fileExists(atPath: store.backupURL.path) }

    init() {
        loadProfiles()
        refresh()
    }

    var activeProfile: Profile? {
        if case .profile(let p) = mode { return p }
        return nil
    }

    var isOnAnthropic: Bool { mode == .anthropic }

    // MARK: - Reading current state

    /// Re-reads everything from disk. Cheap, and the only honest way to answer "which am I on?" —
    /// the file can change under us from an editor or another tool.
    func refresh() {
        do {
            let env = try store.readManagedEnvironment()
            guard let baseURL = env["ANTHROPIC_BASE_URL"], !baseURL.isEmpty else {
                mode = .anthropic
                probe = nil
                lastError = nil
                refreshDiagnostics()
                return
            }
            let model = env["ANTHROPIC_MODEL"] ?? ""
            if let match = profiles.first(where: { $0.baseURL == baseURL && $0.model == model }) {
                mode = .profile(match)
            } else {
                mode = .unrecognised(baseURL: baseURL, model: model)
            }
            lastError = nil
        } catch {
            mode = .anthropic
            lastError = "Could not read \(store.url.path): \(error.localizedDescription)"
        }
        refreshDiagnostics()
    }

    private func refreshDiagnostics() {
        shellOverrides = Diagnostics.shellOverrides()
        runningCLISessions = Diagnostics.runningCLISessionCount()
    }

    // MARK: - Switching

    func switchTo(_ profile: Profile) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        lastError = nil
        statusNote = nil

        guard profile.isUsable else {
            lastError = profile.staticWarnings
                .filter { $0.severity == .blocking }
                .map(\.message)
                .joined(separator: "\n")
            return
        }
        guard let token = KeychainStore.load(for: profile.id), !token.isEmpty else {
            lastError = "No LiteLLM key saved for “\(profile.name)”. Add one in Settings — the "
                + "gateway answers 401 without it."
            return
        }

        // Verify before writing. Switching into a broken gateway means the failure shows up as a
        // mystery 500 on the user's next turn, in a session they have already started.
        let result = await GatewayProbe.run(profile: profile, authToken: token)
        probe = result
        guard result.isHealthy else {
            lastError = "Did not switch — \(profile.name) failed its check. Your settings are "
                + "untouched and the profile is still saved.\n"
                + result.findings.filter { $0.severity == .blocking }
                    .map { "• " + $0.message }.joined(separator: "\n")
            return
        }

        do {
            try store.apply(profile: profile, authToken: token)
            refresh()
            statusNote = restartNote()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func switchToAnthropic() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        lastError = nil
        statusNote = nil
        do {
            try store.clearManagedEnvironment()
            refresh()
            var note = restartNote()
            if !shellOverrides.isEmpty {
                note += "\n\nHeads up: \(shellOverrides.count) shell export"
                    + (shellOverrides.count == 1 ? "" : "s")
                    + " can now take effect again, because settings.json no longer overrides them. "
                    + "See Diagnostics."
            }
            statusNote = note
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Claude Code reads settings at launch, so nothing already running has moved.
    private func restartNote() -> String {
        var parts = ["Claude Code reads settings at launch."]
        if ClaudeDesktopApp.isRunning {
            parts.append("Relaunch the desktop app to pick this up.")
        }
        if runningCLISessions > 0 {
            parts.append("\(runningCLISessions) CLI session"
                + (runningCLISessions == 1 ? " is" : "s are")
                + " still on the old destination; start a new one.")
        }
        return parts.joined(separator: " ")
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
        let token = KeychainStore.load(for: profile.id) ?? ""
        probe = await GatewayProbe.run(profile: profile, authToken: token)
    }

    func check(_ profile: Profile) async -> GatewayProbe.Result {
        let token = KeychainStore.load(for: profile.id) ?? ""
        return await GatewayProbe.run(profile: profile, authToken: token)
    }

    // MARK: - Profile persistence

    func loadProfiles() {
        guard let data = try? Data(contentsOf: profilesURL),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data)
        else {
            profiles = [.aiserver()]
            saveProfiles()
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
            lastError = "Could not save profiles: \(error.localizedDescription)"
        }
        // A rename or a changed base URL changes what "active" means; re-derive it.
        refresh()
    }

    func addProfile() -> Profile {
        var new = Profile.aiserver()
        new.id = UUID()
        new.name = "New gateway"
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

        // An edit to the live profile has to reach settings.json, or the menu and the file disagree.
        if wasActive, let token = KeychainStore.load(for: profile.id), !token.isEmpty {
            try? store.apply(profile: profile, authToken: token)
            refresh()
            statusNote = "Updated the live configuration. " + restartNote()
        }
    }

    func revealSettingsFile() {
        NSWorkspace.shared.selectFile(store.url.path,
                                      inFileViewerRootedAtPath: store.url.deletingLastPathComponent().path)
    }
}
