import Foundation

/// Every environment key that decides where a Claude Code turn goes, with where each value comes
/// from and whether it reaches the CLI and the desktop.
///
/// Three sources can set the same key, and they do not agree on precedence the same way for
/// both apps: `settings.json` beats the shell for the CLI, while the desktop sets some keys
/// itself and Claude Code then ignores the settings file for exactly those keys.
public struct EnvironmentReport {
    public enum Reach: String {
        case both = "CLI and desktop"
        case cliOnly = "CLI only — the desktop sets this itself"
    }

    public struct Row: Identifiable, Hashable {
        public var id: String { key }
        public let key: String
        /// What the active profile wants, masked when secret. nil on Anthropic.
        public let expected: String?
        /// What `settings.json` holds, masked when secret.
        public let inSettings: String?
        /// Dotfile lines that export this key.
        public let shellExports: [String]
        public let reach: Reach
        public let isSecret: Bool

        /// Decided on the raw values before masking — two different keys can mask alike.
        public let status: Status

        public enum Status: Hashable {
            case unset, set, mismatch, missing, stray
        }

        static func status(expected: String?, current: String?) -> Status {
            switch (expected, current) {
            case (nil, nil): .unset
            case (nil, .some): .stray
            case (.some, nil): .missing
            case let (.some(want), .some(have)): want == have ? .set : .mismatch
            }
        }
    }

    public let rows: [Row]

    public init(rows: [Row]) { self.rows = rows }

    /// Keys the desktop injects into every Code session it hosts, which therefore never come
    /// from settings.json there. Read from Claude Desktop 2.110's session launcher.
    public static let desktopOwnedKeys: Set<String> = [
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
        "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_OAUTH_TOKEN",
    ]

    static let secretKeys: Set<String> = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]

    /// Keys that are not ClaudeSwitch's but change the outcome when present, so they are shown.
    public static let relatedKeys = ["ANTHROPIC_API_KEY", "ANTHROPIC_CUSTOM_HEADERS", "API_TIMEOUT_MS",
                                     "CLAUDE_CODE_MAX_RETRIES", "MAX_THINKING_TOKENS"]

    public static func build(profile: Profile?, token: String?, managed: [String: String],
                             unmanaged: [String: String],
                             shell: [Diagnostics.ShellOverride]) -> EnvironmentReport {
        let wanted = Dictionary(
            (profile?.environment(authToken: token ?? "") ?? []).map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first })
        var rows: [Row] = []
        for key in ClaudeSettingsStore.managedKeys + relatedKeys {
            let secret = secretKeys.contains(key)
            let expected = wanted[key]
            let current = managed[key] ?? unmanaged[key]
            let exports = shell.filter { $0.variable == key }.map { "~/\($0.file):\($0.line)" }
            // Unrelated keys that nobody set are noise.
            if relatedKeys.contains(key), current == nil, exports.isEmpty { continue }
            rows.append(Row(key: key,
                            expected: expected.map { secret ? mask($0) : $0 },
                            inSettings: current.map { secret ? mask($0) : $0 },
                            shellExports: exports,
                            reach: desktopOwnedKeys.contains(key) ? .cliOnly : .both,
                            isSecret: secret,
                            status: Row.status(expected: expected, current: current)))
        }
        return EnvironmentReport(rows: rows)
    }

    /// Enough to recognise a key, never enough to use one. Placeholders are not secret.
    public static func mask(_ value: String) -> String {
        if value.isEmpty { return "(empty)" }
        if Provider.allCases.contains(where: { $0.placeholderToken == value }) { return value }
        // A conventional "sk-" prefix identifies the kind of key and nothing about the key.
        let prefix = value.hasPrefix("sk-") ? "sk-" : ""
        return "\(prefix)•••• (\(value.count) chars)"
    }
}
