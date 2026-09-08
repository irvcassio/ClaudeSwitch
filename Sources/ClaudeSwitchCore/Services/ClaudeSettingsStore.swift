import Foundation

/// Reads and writes the `env` block of a Claude Code settings file.
///
/// Only the keys in `managedKeys` are ever touched. Anything else in the file — permissions,
/// hooks, statusLine, plugins, and any `env` key the user set by hand — is preserved exactly,
/// including key order. `settings.json` beats the shell, so this is the one place that decides
/// where turns go for both the desktop app and the CLI.
public struct ClaudeSettingsStore {
    /// Every key this app owns. Switching back to Anthropic removes exactly these and nothing else.
    public static let managedKeys = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "CLAUDE_CODE_EFFORT_LEVEL",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
        "CLAUDE_CODE_MAX_OUTPUT_TOKENS",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
    ]

    public let url: URL

    public static var userSettings: ClaudeSettingsStore {
        ClaudeSettingsStore(url: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json"))
    }

    // MARK: - Reading

    /// The managed env keys currently on disk. Empty means Claude Code is on the subscription.
    public func readManagedEnvironment() throws -> [String: String] {
        guard let root = try readRoot(), let env = root["env"]?.objectEntries else { return [:] }
        var out: [String: String] = [:]
        for entry in env where Self.managedKeys.contains(entry.key) {
            // A non-string here is invalid for env anyway; render it so the UI can show the truth.
            out[entry.key] = entry.value.stringValue ?? entry.value.serialized()
        }
        return out
    }

    /// `env` keys the user set themselves. Shown in diagnostics so an unexplained override is visible.
    public func readUnmanagedEnvironment() throws -> [String: String] {
        guard let root = try readRoot(), let env = root["env"]?.objectEntries else { return [:] }
        var out: [String: String] = [:]
        for entry in env where !Self.managedKeys.contains(entry.key) {
            out[entry.key] = entry.value.stringValue ?? entry.value.serialized()
        }
        return out
    }

    private func readRoot() throws -> JSONValue? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try JSONValue.parse(text)
    }

    // MARK: - Writing

    /// Points Claude Code at `profile`. Replaces the managed keys wholesale so a profile that
    /// drops an optional key does not leave the old value behind.
    public func apply(profile: Profile, authToken: String) throws {
        try mutate { root in
            var env = root["env"]?.objectEntries ?? []
            env.removeAll { Self.managedKeys.contains($0.key) }
            for pair in profile.environment(authToken: authToken) {
                env.append((key: pair.key, value: .string(pair.value)))
            }
            root["env"] = .object(env)
        }
    }

    /// Returns Claude Code to the Anthropic subscription by removing every managed key.
    /// An `env` block left empty by this is removed too, rather than leaving `"env": {}` behind.
    public func clearManagedEnvironment() throws {
        try mutate { root in
            guard var env = root["env"]?.objectEntries else { return }
            env.removeAll { Self.managedKeys.contains($0.key) }
            root["env"] = env.isEmpty ? nil : .object(env)
        }
    }

    private func mutate(_ transform: (inout JSONValue) throws -> Void) throws {
        var root = try readRoot() ?? .object([])
        guard case .object = root else { throw StoreError.notAnObject(url) }

        try backupOnce()
        try transform(&root)

        let text = root.serialized() + "\n"
        try writeAtomically(text)
    }

    /// Writes via a temporary file in the same directory, so a crash mid-write cannot leave a
    /// half-written settings.json — the file either has the old contents or the new ones.
    private func writeAtomically(_ text: String) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".claudeswitch-\(UUID().uuidString).tmp")
        try text.write(to: temporary, atomically: false, encoding: .utf8)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Keeps one pristine copy from before this app ever touched the file.
    public var backupURL: URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".claudeswitch-backup")
    }

    private func backupOnce() throws {
        guard FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: backupURL.path)
        else { return }
        try FileManager.default.copyItem(at: url, to: backupURL)
    }

    public enum StoreError: LocalizedError {
        case notAnObject(URL)
        public var errorDescription: String? {
            switch self {
            case .notAnObject(let url):
                "\(url.path) does not contain a JSON object at its top level."
            }
        }
    }
}
