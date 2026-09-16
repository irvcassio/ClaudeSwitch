import Foundation

/// A destination Claude Code can be pointed at.
///
/// `.anthropic` is the absence of configuration: no managed env keys on disk, so Claude Code
/// falls back to the subscription. Every profile is a server that speaks the Anthropic Messages
/// API — LM Studio or Ollama on this Mac, or a LiteLLM proxy somewhere else.
public struct Profile: Codable, Identifiable, Hashable {
    public var id: UUID = UUID()
    public var name: String
    public var provider: Provider
    public var baseURL: String
    public var model: String
    /// Background work (titles, summaries) resolves the `haiku` alias, never `ANTHROPIC_MODEL`.
    /// Left unmapped, sessions work but titles never appear.
    public var haikuModel: String
    public var sonnetModel: String
    public var opusModel: String
    /// Qwen3.8's chat template accepts low/medium/xhigh only; Claude Code defaults to `high`,
    /// which returns HTTP 500 on the first turn.
    public var effortLevel: String
    /// The window Claude Code works within: `CLAUDE_CODE_MAX_CONTEXT_TOKENS` and
    /// `CLAUDE_CODE_AUTO_COMPACT_WINDOW`. Not the server's length — see `LimitPlan`.
    public var contextWindow: Int
    public var maxOutputTokens: Int
    /// The server's real ceiling on prompt + output, as discovered from the server. 0 when it has
    /// not been discovered, in which case the window cannot be checked against it.
    public var modelLength: Int
    public var disableNonessentialTraffic: Bool
    public var enableGatewayModelDiscovery: Bool
    /// Also move Claude Desktop, through its own third-party configuration. The desktop ignores
    /// the base URL and key in settings.json, so this is the only way to reach it.
    public var switchesDesktop: Bool
    /// Route through ClaudeSwitch's loopback compatibility relay on this port. 0 means Claude Code
    /// talks to `baseURL` directly. See `CompatibilityRelay`.
    public var relayPort: Int
    /// The SHA-256 of the private CA this destination's certificate chains to, when the user has
    /// trusted one. Recorded so the destination can say *which* anchor it needs, and so
    /// `NODE_EXTRA_CA_CERTS` is written only for destinations that actually need it. See
    /// `TLSTrust`.
    public var caAnchorFingerprint: String?

    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]
    /// Values Qwen3.8 will actually accept. `high` and `max` 500 on the first turn.
    public static let qwenSafeEffortLevels = ["low", "medium", "xhigh"]

    public init(id: UUID = UUID(), name: String, provider: Provider, baseURL: String, model: String,
                haikuModel: String, sonnetModel: String, opusModel: String, effortLevel: String,
                contextWindow: Int, maxOutputTokens: Int, modelLength: Int = 0,
                disableNonessentialTraffic: Bool, enableGatewayModelDiscovery: Bool,
                switchesDesktop: Bool = false, relayPort: Int = 0,
                caAnchorFingerprint: String? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.haikuModel = haikuModel
        self.sonnetModel = sonnetModel
        self.opusModel = opusModel
        self.effortLevel = effortLevel
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.modelLength = modelLength
        self.disableNonessentialTraffic = disableNonessentialTraffic
        self.enableGatewayModelDiscovery = enableGatewayModelDiscovery
        self.switchesDesktop = switchesDesktop
        self.relayPort = relayPort
        self.caAnchorFingerprint = caAnchorFingerprint
    }

    /// The first port the relay offers. Chosen from the dynamic range, away from anything the
    /// providers ClaudeSwitch knows about listen on.
    public static let firstRelayPort = 47_810

    public var usesRelay: Bool { relayPort > 0 }

    /// The address Claude Code is given: the relay when it is on, the server otherwise.
    public var clientBaseURL: String {
        usesRelay ? "http://127.0.0.1:\(relayPort)" : baseURL
    }

    /// An empty destination for the user to fill in. It carries a provider's standard local
    /// address when there is one, and nothing else: ClaudeSwitch ships knowing nobody's network,
    /// so a remote proxy starts with no address and no model ids. The numeric defaults are the
    /// only safe guesses — they are limits, not a destination — and discovery replaces them.
    public static func blank(name: String = "New destination", provider: Provider = .liteLLM) -> Profile {
        Profile(
            name: name,
            provider: provider,
            baseURL: provider.defaultBaseURL,
            model: "",
            haikuModel: "",
            sonnetModel: "",
            opusModel: "",
            effortLevel: "medium",
            contextWindow: 131072,
            maxOutputTokens: LimitPlan.defaultMaxOutputTokens,
            disableNonessentialTraffic: true,
            enableGatewayModelDiscovery: false
        )
    }

    /// The token written for `ANTHROPIC_AUTH_TOKEN`: the saved key, or the provider's
    /// placeholder when it needs none.
    public func effectiveToken(savedKey: String?) -> String? {
        if let savedKey, !savedKey.isEmpty { return savedKey }
        return provider.placeholderToken
    }

    /// The env block this profile writes into `settings.json`.
    public func environment(authToken: String) -> [(key: String, value: String)] {
        var env: [(key: String, value: String)] = [
            ("ANTHROPIC_BASE_URL", clientBaseURL),
            ("ANTHROPIC_AUTH_TOKEN", authToken),
            ("ANTHROPIC_MODEL", model),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", haikuModel),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", sonnetModel),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", opusModel),
            ("CLAUDE_CODE_EFFORT_LEVEL", effortLevel),
            // Both, with the same value. For a model whose id does not start with "claude-",
            // Claude Code takes its window from CLAUDE_CODE_MAX_CONTEXT_TOKENS (default 200,000)
            // and caps the compact window at it — so the compact window alone is silently
            // capped at 200K. And the compact window is clamped to at least 100,000, so for a
            // smaller model the context-tokens key is the only one that can bring it down.
            ("CLAUDE_CODE_MAX_CONTEXT_TOKENS", String(contextWindow)),
            ("CLAUDE_CODE_AUTO_COMPACT_WINDOW", String(contextWindow)),
        ]
        if maxOutputTokens > 0 {
            env.append(("CLAUDE_CODE_MAX_OUTPUT_TOKENS", String(maxOutputTokens)))
        }
        if disableNonessentialTraffic {
            env.append(("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"))
        }
        if enableGatewayModelDiscovery {
            env.append(("CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY", "1"))
        }
        // Claude Code runs on Node, which ignores the macOS keychain — so trusting the gateway's
        // CA there fixes the desktop app and leaves the CLI failing with
        // UNABLE_TO_VERIFY_LEAF_SIGNATURE. This is the only thing that reaches Node. See `TLSTrust`.
        if caAnchorFingerprint != nil {
            env.append(("NODE_EXTRA_CA_CERTS", TLSTrust.bundlePath.path(percentEncoded: false)))
        }
        return env
    }

    /// Applies discovered limits: the server length, and a window and output ceiling that fit
    /// inside it. The output ceiling the user chose is kept unless the server cannot take it.
    public mutating func adopt(_ plan: LimitPlan) {
        modelLength = plan.modelLength
        maxOutputTokens = plan.maxOutputTokens
        contextWindow = plan.compactWindow
    }

    /// Profiles saved before providers existed were all LiteLLM proxies, and carried no
    /// discovered length. Missing fields decode to those facts rather than failing the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .liteLLM
        baseURL = try c.decode(String.self, forKey: .baseURL)
        model = try c.decode(String.self, forKey: .model)
        haikuModel = try c.decode(String.self, forKey: .haikuModel)
        sonnetModel = try c.decode(String.self, forKey: .sonnetModel)
        opusModel = try c.decode(String.self, forKey: .opusModel)
        effortLevel = try c.decode(String.self, forKey: .effortLevel)
        contextWindow = try c.decode(Int.self, forKey: .contextWindow)
        maxOutputTokens = try c.decode(Int.self, forKey: .maxOutputTokens)
        modelLength = try c.decodeIfPresent(Int.self, forKey: .modelLength) ?? 0
        disableNonessentialTraffic = try c.decode(Bool.self, forKey: .disableNonessentialTraffic)
        enableGatewayModelDiscovery = try c.decode(Bool.self, forKey: .enableGatewayModelDiscovery)
        switchesDesktop = try c.decodeIfPresent(Bool.self, forKey: .switchesDesktop) ?? false
        relayPort = try c.decodeIfPresent(Int.self, forKey: .relayPort) ?? 0
        caAnchorFingerprint = try c.decodeIfPresent(String.self, forKey: .caAnchorFingerprint)
    }
}

// MARK: - Validation

/// A problem worth surfacing before the user switches, not after a failed first turn.
public struct Warning: Identifiable, Hashable {
    public enum Severity: Hashable { case blocking, caution }
    public let id = UUID()
    public let severity: Severity
    public let message: String

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}

extension Profile {
    var port: Int? { URLComponents(string: baseURL)?.port }

    var isLoopback: Bool { Self.isLoopback(baseURL) }

    static func isLoopback(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// Checks that do not need the network.
    public var staticWarnings: [Warning] {
        var out: [Warning] = []

        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            out.append(Warning(severity: .blocking, message: "Base URL is empty."))
        } else if let components = URLComponents(string: trimmed),
                  let scheme = components.scheme, ["http", "https"].contains(scheme),
                  components.host?.isEmpty == false {
            if trimmed.hasSuffix("/v1") || trimmed.hasSuffix("/v1/") {
                out.append(Warning(severity: .blocking, message:
                    "Drop the /v1 from the base URL. Claude Code appends the Anthropic paths itself, "
                    + "so /v1 here produces /v1/v1/messages."))
            }
        } else {
            out.append(Warning(severity: .blocking, message: "Base URL is not a valid http(s) URL."))
        }

        // A proxy profile aimed at a port a local server owns is almost always the wrong
        // provider picked, and the difference matters: the key and discovery both change.
        if provider == .liteLLM, let port {
            if port == 1234 {
                out.append(Warning(severity: .caution, message:
                    "Port 1234 is LM Studio's. Choose LM Studio as the provider so no key is required "
                    + "and the loaded context length is read from the server."))
            } else if port == 11434 {
                out.append(Warning(severity: .caution, message:
                    "Port 11434 is Ollama's. Choose Ollama as the provider."))
            }
        }

        for (label, id) in [("Model", model), ("Haiku", haikuModel), ("Sonnet", sonnetModel), ("Opus", opusModel)] {
            let lower = id.lowercased()
            if id.isEmpty {
                out.append(Warning(severity: .blocking, message: "\(label) model is empty."))
            } else if provider.expectsClaudeLikeIDs, enableGatewayModelDiscovery,
                      !lower.contains("claude"), !lower.contains("anthropic") {
                out.append(Warning(severity: .caution, message:
                    "\(label) model '\(id)' has neither 'claude' nor 'anthropic' in its id, so "
                    + "/model will hide it. The session still works — this only affects the picker."))
            }
        }

        let modelsNames = [model, haikuModel, sonnetModel, opusModel].joined(separator: " ").lowercased()
        if modelsNames.contains("qwen3.8") || modelsNames.contains("qwen38"),
           !Self.qwenSafeEffortLevels.contains(effortLevel) {
            out.append(Warning(severity: .caution, message:
                "Effort '\(effortLevel)' returns HTTP 500 against Qwen3.8, which accepts low, "
                + "medium and xhigh only."))
        }

        if contextWindow <= 0 {
            out.append(Warning(severity: .blocking, message: "Context window must be greater than zero."))
        } else if contextWindow < LimitPlan.minimumUsefulWindow {
            out.append(Warning(severity: .caution, message:
                "A context window under \(LimitPlan.minimumUsefulWindow.formatted()) tokens is smaller "
                + "than Claude Code's own system prompt and tools need; it will compact constantly."))
        }

        if maxOutputTokens <= 0 {
            out.append(Warning(severity: .blocking, message:
                "Set a max output. Without one Claude Code asks for its own default on every turn, "
                + "which this server may not accept, and a thinking model has nothing to stop it "
                + "spiralling."))
        } else if maxOutputTokens < 4_096 {
            out.append(Warning(severity: .caution, message:
                "Reasoning counts towards max output. Below 4,096 a thinking model often spends it "
                + "all thinking and replies with nothing."))
        }

        if let problem = LimitPlan.problem(modelLength: modelLength, compactWindow: contextWindow,
                                           maxOutputTokens: maxOutputTokens) {
            out.append(Warning(severity: .blocking, message: problem))
        } else if modelLength == 0, provider != .custom {
            out.append(Warning(severity: .caution, message:
                "The server's length has not been discovered, so the context window cannot be "
                + "checked against it. Use Discover to read it from the server."))
        }

        if baseURL.hasPrefix("http://"), !isLoopback, provider.requiresKey {
            out.append(Warning(severity: .caution, message:
                "Plain HTTP: the key crosses the network in the clear on every request. Treat it as "
                + "low-assurance and do not reuse it as a password."))
        }

        if usesRelay, !(1_024...65_535).contains(relayPort) {
            out.append(Warning(severity: .blocking, message:
                "Relay port \(relayPort) is outside 1024–65535."))
        }
        if usesRelay, isLoopback, provider != .liteLLM, provider != .custom {
            out.append(Warning(severity: .caution, message:
                "\(provider.displayName) already takes Claude Code's requests as they are; the relay is "
                + "only needed for servers that reject them."))
        }

        if switchesDesktop, let reason = DesktopGatewayStore.ineligibility(of: self) {
            out.append(Warning(severity: .blocking, message: reason))
        }

        return out
    }

    public var isUsable: Bool { !staticWarnings.contains { $0.severity == .blocking } }
}
