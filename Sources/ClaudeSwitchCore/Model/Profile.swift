import Foundation

/// A destination Claude Code can be pointed at.
///
/// `.anthropic` is the absence of configuration: no managed env keys on disk, so Claude Code
/// falls back to the subscription. Every other profile is a gateway that speaks the Anthropic
/// Messages API — typically a LiteLLM proxy you run yourself.
public struct Profile: Codable, Identifiable, Hashable {
    public var id: UUID = UUID()
    public var name: String
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
    /// Must match what vLLM was started with, or compaction fires at the wrong moment.
    public var contextWindow: Int
    public var maxOutputTokens: Int
    public var disableNonessentialTraffic: Bool
    public var enableGatewayModelDiscovery: Bool

    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]
    /// Values Qwen3.8 will actually accept. `high` and `max` 500 on the first turn.
    public static let qwenSafeEffortLevels = ["low", "medium", "xhigh"]

    /// An empty gateway for the user to fill in. Deliberately carries no address and no model
    /// ids — ClaudeSwitch ships with no gateway of its own, so nothing here points anywhere
    /// until someone types it. The numeric defaults are the only safe guesses: they are the
    /// limits, not the destination.
    public static func blank(name: String = "New gateway") -> Profile {
        Profile(
            name: name,
            baseURL: "",
            model: "",
            haikuModel: "",
            sonnetModel: "",
            opusModel: "",
            effortLevel: "medium",
            contextWindow: 131072,
            maxOutputTokens: 16384,
            disableNonessentialTraffic: true,
            enableGatewayModelDiscovery: false
        )
    }

    /// The env block this profile writes into `settings.json`.
    public func environment(authToken: String) -> [(key: String, value: String)] {
        var env: [(key: String, value: String)] = [
            ("ANTHROPIC_BASE_URL", baseURL),
            ("ANTHROPIC_AUTH_TOKEN", authToken),
            ("ANTHROPIC_MODEL", model),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", haikuModel),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", sonnetModel),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", opusModel),
            ("CLAUDE_CODE_EFFORT_LEVEL", effortLevel),
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
        return env
    }
}

// MARK: - Validation

/// A problem worth surfacing before the user switches, not after a failed first turn.
public struct Warning: Identifiable, Hashable {
    public enum Severity: Hashable { case blocking, caution }
    public let id = UUID()
    public let severity: Severity
    public let message: String
}

extension Profile {
    /// Checks that do not need the network.
    public var staticWarnings: [Warning] {
        var out: [Warning] = []

        if baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(Warning(severity: .blocking, message: "Base URL is empty."))
        } else if URL(string: baseURL) == nil {
            out.append(Warning(severity: .blocking, message: "Base URL is not a valid URL."))
        }

        if baseURL.hasSuffix("/v1") || baseURL.hasSuffix("/v1/") {
            out.append(Warning(severity: .blocking, message:
                "Drop the /v1 from the base URL. Claude Code appends the Anthropic paths itself, "
                + "so /v1 here produces /v1/v1/messages."))
        }

        if baseURL.contains(":8001") {
            out.append(Warning(severity: .blocking, message:
                "Port 8001 is vLLM. It is loopback-only and has no /v1/messages route, so the "
                + "first turn 404s. Use the gateway on :4000."))
        }

        if baseURL.contains(":11434") {
            out.append(Warning(severity: .blocking, message:
                "Port 11434 is Ollama — no auth, open for two legacy consumers, and on the list "
                + "to be closed. Use the gateway on :4000."))
        }

        for (label, id) in [("Model", model), ("Haiku", haikuModel), ("Sonnet", sonnetModel), ("Opus", opusModel)] {
            let lower = id.lowercased()
            if id.isEmpty {
                out.append(Warning(severity: .blocking, message: "\(label) model is empty."))
            } else if !lower.contains("claude"), !lower.contains("anthropic") {
                out.append(Warning(severity: .caution, message:
                    "\(label) model '\(id)' has neither 'claude' nor 'anthropic' in its id, so "
                    + "/model will hide it. The session still works — this only affects the picker."))
            }
        }

        if !Self.qwenSafeEffortLevels.contains(effortLevel) {
            out.append(Warning(severity: .caution, message:
                "Effort '\(effortLevel)' returns HTTP 500 against Qwen3.8, which accepts low, "
                + "medium and xhigh only. Harmless if this gateway fronts a different model."))
        }

        if contextWindow <= 0 {
            out.append(Warning(severity: .blocking, message: "Context window must be greater than zero."))
        }

        if baseURL.hasPrefix("http://"), !baseURL.contains("127.0.0.1"), !baseURL.contains("localhost") {
            out.append(Warning(severity: .caution, message:
                "Plain HTTP: the key crosses the LAN in the clear on every request. Treat it as "
                + "low-assurance and do not reuse it as a password."))
        }

        return out
    }

    public var isUsable: Bool { !staticWarnings.contains { $0.severity == .blocking } }
}
