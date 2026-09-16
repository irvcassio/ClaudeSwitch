import Foundation

/// Moves Claude Desktop between Claude.ai and a gateway, through the desktop's own
/// third-party configuration.
///
/// The desktop cannot be moved through `~/.claude/settings.json`. It sets `ANTHROPIC_BASE_URL`
/// and an empty `ANTHROPIC_AUTH_TOKEN` for every Code session it hosts, and Claude Code drops a
/// settings-file key the host has already set. Its supported route is "Claude Desktop on 3P":
/// a gateway configuration the app reads at launch, and a sign-in screen that offers either
/// Claude.ai or that gateway.
///
/// This store writes the same local configuration the desktop's own **Developer → Configure
/// Third-Party Inference… → Apply Changes** writes — one entry in its configuration library,
/// marked applied — and the saved deployment mode that decides which side the app opens on.
/// It never touches managed preferences (MDM), and never an entry it did not create.
///
/// Layout, under `~/Library/Application Support/Claude-3p/`:
///
/// * `configLibrary/_meta.json` — `{"appliedId": "<uuid>", "entries": [{"id", "name"}]}`
/// * `configLibrary/<uuid>.json` — one configuration, flat keys, values encoded as strings
/// * `claude_desktop_config.json` — `"deploymentMode": "3p" | "1p"`, among the app's other keys
public struct DesktopGatewayStore {
    public static let entryName = "ClaudeSwitch"

    public let root: URL

    public init(root: URL) { self.root = root }

    public static var user: DesktopGatewayStore {
        DesktopGatewayStore(root: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude-3p"))
    }

    var libraryURL: URL { root.appending(path: "configLibrary") }
    var metaURL: URL { libraryURL.appending(path: "_meta.json") }
    var appConfigURL: URL { root.appending(path: "claude_desktop_config.json") }
    func entryURL(_ id: String) -> URL { libraryURL.appending(path: "\(id).json") }
    /// Which configuration was applied before ClaudeSwitch applied its own, so switching back
    /// leaves the user's own setup as it was.
    var stashURL: URL { libraryURL.appending(path: "_claudeswitch-previous-applied") }

    /// The managed-preferences file that, when present, overrides everything here. The desktop
    /// opens its configuration window read-only on such a device.
    public static let managedPreferencePaths: [String] = {
        let user = NSUserName()
        return ["/Library/Managed Preferences/\(user)/com.anthropic.claudefordesktop.plist",
                "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"]
    }()

    // MARK: - Eligibility

    /// Why this profile cannot drive the desktop, or nil when it can. The desktop accepts a
    /// gateway URL only over HTTPS, or plain HTTP on this Mac's loopback address.
    public static func ineligibility(of profile: Profile) -> String? {
        let url = profile.clientBaseURL
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased() else { return nil }
        if scheme == "https" || Profile.isLoopback(url) { return nil }
        return "Claude Desktop only accepts a gateway over HTTPS, or plain HTTP on this Mac "
            + "(127.0.0.1). \(url) is plain HTTP on the network, so the desktop would refuse it. "
            + "Turn on the compatibility relay (the desktop then talks to 127.0.0.1), put TLS in "
            + "front of the proxy, or turn off “Also switch Claude Desktop” — the CLI still switches."
    }

    // MARK: - State

    public enum Mode: String { case claudeAI = "1p", gateway = "3p" }

    public struct State: Equatable {
        /// The saved sign-in choice. nil until the desktop has ever shown its chooser.
        public var mode: Mode?
        public var entryID: String?
        public var entryApplied: Bool
        public var baseURL: String?
        public var models: [String]
        public var hasKey: Bool
        public var managedByMDM: Bool

        /// The desktop will open on ClaudeSwitch's gateway at its next launch.
        public var isOnGateway: Bool { mode == .gateway && entryApplied }
    }

    public func state() -> State {
        let meta = readJSON(metaURL)
        let entryID = ownEntryID(in: meta)
        let applied = entryID != nil && meta?["appliedId"]?.stringValue == entryID
        var baseURL: String?
        var models: [String] = []
        var hasKey = false
        if let entryID, let entry = readJSON(entryURL(entryID)) {
            baseURL = entry["inferenceGatewayBaseUrl"]?.stringValue
            hasKey = !(entry["inferenceGatewayApiKey"]?.stringValue ?? "").isEmpty
            if let text = entry["inferenceModels"]?.stringValue,
               let data = text.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                models = list.compactMap { ($0 as? String) ?? ($0 as? [String: Any])?["name"] as? String }
            }
        }
        let mode = readJSON(appConfigURL)?["deploymentMode"]?.stringValue.flatMap(Mode.init(rawValue:))
        let managed = Self.managedPreferencePaths.contains { FileManager.default.fileExists(atPath: $0) }
        return State(mode: mode, entryID: entryID, entryApplied: applied, baseURL: baseURL,
                     models: models, hasKey: hasKey, managedByMDM: managed)
    }

    // MARK: - Switching

    /// Points the desktop at `profile`: writes ClaudeSwitch's entry, applies it, and saves the
    /// gateway as the side to open on. Takes effect at the desktop's next launch.
    public func activate(profile: Profile, token: String) throws {
        if let reason = Self.ineligibility(of: profile) { throw StoreError.ineligible(reason) }
        if state().managedByMDM { throw StoreError.managed }

        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        var meta = readJSON(metaURL) ?? .object([("appliedId", .string("")), ("entries", .array([]))])
        guard case .object = meta else { throw StoreError.unreadable(metaURL) }

        let id = ownEntryID(in: meta) ?? UUID().uuidString.lowercased()
        try write(Self.entry(for: profile, token: token), to: entryURL(id), privateFile: true)

        var entries = meta["entries"].flatMap(arrayValue) ?? []
        if !entries.contains(where: { $0["id"]?.stringValue == id }) {
            entries.append(.object([("id", .string(id)), ("name", .string(Self.entryName))]))
        }
        meta["entries"] = .array(entries)

        let previous = meta["appliedId"]?.stringValue ?? ""
        if previous != id, !previous.isEmpty {
            try Data(previous.utf8).write(to: stashURL, options: .atomic)
        }
        meta["appliedId"] = .string(id)
        try write(meta, to: metaURL)
        try setMode(.gateway)
    }

    /// Returns the desktop to Claude.ai at its next launch. The key comes off disk, and whatever
    /// configuration the user had applied before is applied again. ClaudeSwitch's entry stays,
    /// keyless, so the desktop's own window still shows what was used.
    public func deactivate() throws {
        guard FileManager.default.fileExists(atPath: appConfigURL.path)
            || FileManager.default.fileExists(atPath: metaURL.path) else { return }
        try setMode(.claudeAI)

        guard var meta = readJSON(metaURL), let id = ownEntryID(in: meta) else { return }
        if var entry = readJSON(entryURL(id)) {
            entry["inferenceGatewayApiKey"] = nil
            try write(entry, to: entryURL(id), privateFile: true)
        }
        if meta["appliedId"]?.stringValue == id,
           let previous = try? String(contentsOf: stashURL, encoding: .utf8),
           (meta["entries"].flatMap(arrayValue) ?? []).contains(where: { $0["id"]?.stringValue == previous }) {
            meta["appliedId"] = .string(previous)
            try write(meta, to: metaURL)
        }
        try? FileManager.default.removeItem(at: stashURL)
    }

    /// The desktop configuration for a profile, in the desktop's own key names.
    static func entry(for profile: Profile, token: String) -> JSONValue {
        var models: [[String: Any]] = []
        var seen = Set<String>()
        for (id, tier) in [(profile.model, "sonnet"), (profile.opusModel, "opus"),
                           (profile.haikuModel, "haiku"), (profile.sonnetModel, "sonnet")]
        where !id.isEmpty && seen.insert(id).inserted {
            var model: [String: Any] = [
                "name": id,
                "labelOverride": seen.count == 1 ? "\(profile.name) — \(id)" : id,
                "anthropicFamilyTier": tier,
            ]
            if Profile.effortLevels.contains(profile.effortLevel) {
                model["maxEffort"] = profile.effortLevel
            }
            models.append(model)
        }
        let modelsJSON = (try? JSONSerialization.data(withJSONObject: models, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"

        return .object([
            ("inferenceProvider", .string("gateway")),
            ("inferenceGatewayBaseUrl", .string(profile.clientBaseURL)),
            ("inferenceGatewayApiKey", .string(token)),
            ("inferenceGatewayAuthScheme", .string("bearer")),
            ("inferenceModels", .string(modelsJSON)),
            ("modelDiscoveryEnabled", .string("false")),
            ("defaultModelEffort", .string(profile.effortLevel)),
            ("deploymentDisplayName", .string("ClaudeSwitch — \(profile.name)")),
        ])
    }

    // MARK: - Files

    private func setMode(_ mode: Mode) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = readJSON(appConfigURL) ?? .object([])
        guard case .object = config else { throw StoreError.unreadable(appConfigURL) }
        config["deploymentMode"] = .string(mode.rawValue)
        try write(config, to: appConfigURL)
    }

    private func ownEntryID(in meta: JSONValue?) -> String? {
        guard let entries = meta?["entries"].flatMap(arrayValue) else { return nil }
        return entries.first { $0["name"]?.stringValue == Self.entryName }?["id"]?.stringValue
    }

    private func arrayValue(_ value: JSONValue) -> [JSONValue]? {
        if case .array(let items) = value { return items }
        return nil
    }

    private func readJSON(_ url: URL) -> JSONValue? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return try? JSONValue.parse(text)
    }

    private func write(_ value: JSONValue, to url: URL, privateFile: Bool = false) throws {
        try Data((value.serialized() + "\n").utf8).write(to: url, options: .atomic)
        if privateFile {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    public enum StoreError: LocalizedError {
        case ineligible(String)
        case managed
        case unreadable(URL)

        public var errorDescription: String? {
            switch self {
            case .ineligible(let reason): reason
            case .managed:
                "Claude Desktop on this Mac is configured by a management profile, which overrides any "
                    + "local configuration. ClaudeSwitch cannot switch it."
            case .unreadable(let url): "\(url.path) is not a JSON object; leaving it alone."
            }
        }
    }
}
