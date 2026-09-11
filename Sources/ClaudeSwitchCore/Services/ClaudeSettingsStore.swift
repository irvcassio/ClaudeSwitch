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

    /// Top-level settings that outrank the managed `env` block: `model` beats `ANTHROPIC_MODEL`,
    /// and `effortLevel` beats `CLAUDE_CODE_EFFORT_LEVEL`. Left in place they make a switch look
    /// successful while Claude Code keeps asking for a model the gateway does not publish, or for
    /// an effort level it answers with HTTP 500. So they are set aside on the way to a gateway and
    /// put back — in the position they were found — on the way back to Anthropic.
    public static let overridingTopLevelKeys = ["model", "effortLevel"]

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

    /// The overriding top-level keys currently on disk. Non-empty while on a gateway means the
    /// switch is being undermined; the app sets them aside so this normally reads empty.
    public func readTopLevelOverrides() throws -> [String: String] {
        guard let root = try readRoot(), let entries = root.objectEntries else { return [:] }
        var out: [String: String] = [:]
        for entry in entries where Self.overridingTopLevelKeys.contains(entry.key) {
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
            try setAsideTopLevelOverrides(in: &root)
        }
    }

    /// Returns Claude Code to the Anthropic subscription by removing every managed key.
    /// An `env` block left empty by this is removed too, rather than leaving `"env": {}` behind.
    public func clearManagedEnvironment() throws {
        try mutate { root in
            if var env = root["env"]?.objectEntries {
                env.removeAll { Self.managedKeys.contains($0.key) }
                root["env"] = env.isEmpty ? nil : .object(env)
            }
            try restoreTopLevelOverrides(in: &root)
        }
        try? FileManager.default.removeItem(at: overridesStashURL)
    }

    // MARK: - Top-level overrides

    /// Where the originals wait while a gateway is active. Sits next to the backup, so a user
    /// who wants to undo everything by hand can see both.
    public var overridesStashURL: URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".claudeswitch-overrides")
    }

    /// `value` holds the original's serialized JSON rather than a string, so a non-string
    /// override survives the round trip; `index` is where it sat among the top-level keys.
    private struct StashedOverride: Codable {
        let key: String
        let index: Int
        let value: String
    }

    private func setAsideTopLevelOverrides(in root: inout JSONValue) throws {
        guard var entries = root.objectEntries else { return }

        var found: [StashedOverride] = []
        for key in Self.overridingTopLevelKeys {
            guard let index = entries.firstIndex(where: { $0.key == key }) else { continue }
            found.append(StashedOverride(key: key, index: index,
                                         value: entries[index].value.serialized()))
        }
        guard !found.isEmpty else { return }

        // Highest index first, so removing one does not shift the next.
        for item in found.sorted(by: { $0.index > $1.index }) { entries.remove(at: item.index) }
        root = .object(entries)

        // An earlier stash is the true "before" state — keep it, and only add keys it is missing
        // (a user can re-add `model` by hand while a gateway is already active).
        var stash = loadStash()
        stash.append(contentsOf: found.filter { item in !stash.contains { $0.key == item.key } })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stash.sorted { $0.index < $1.index })
            .write(to: overridesStashURL, options: .atomic)
    }

    /// Puts each stashed key back where it was found, so the file is byte-for-byte what it was.
    /// Must run after the managed `env` block is gone, or the recorded indices are off by one.
    private func restoreTopLevelOverrides(in root: inout JSONValue) throws {
        let stash = loadStash()
        guard !stash.isEmpty, var entries = root.objectEntries else { return }
        for item in stash.sorted(by: { $0.index < $1.index }) {
            guard !entries.contains(where: { $0.key == item.key }) else { continue }
            let value = try JSONValue.parse(item.value)
            entries.insert((key: item.key, value: value), at: min(item.index, entries.count))
        }
        root = .object(entries)
    }

    private func loadStash() -> [StashedOverride] {
        guard let data = try? Data(contentsOf: overridesStashURL) else { return [] }
        return (try? JSONDecoder().decode([StashedOverride].self, from: data)) ?? []
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
