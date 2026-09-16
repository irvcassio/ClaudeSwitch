import Foundation

/// What kind of server a destination is. It decides the defaults the editor offers, whether a
/// key is needed, and — most importantly — how the destination is asked what it can serve.
///
/// Every kind must speak the Anthropic Messages API on `/v1/messages`, because that is the only
/// dialect Claude Code talks. They differ in everything around it: LM Studio reports the context
/// its loaded instance was started with, Ollama reports it per model, and a LiteLLM proxy
/// reports a model's input limit but not the server's real ceiling, which has to be measured.
public enum Provider: String, Codable, CaseIterable, Identifiable, Hashable {
    case lmStudio
    case liteLLM
    case ollama
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lmStudio: "LM Studio (this Mac)"
        case .liteLLM: "LiteLLM proxy (remote)"
        case .ollama: "Ollama"
        case .custom: "Other Anthropic-compatible server"
        }
    }

    /// Where a stock install listens. Empty for the kinds that have no standard address — a
    /// remote proxy is somebody's network, and ClaudeSwitch ships knowing nobody's network.
    public var defaultBaseURL: String {
        switch self {
        case .lmStudio: "http://127.0.0.1:1234"
        case .ollama: "http://127.0.0.1:11434"
        case .liteLLM, .custom: ""
        }
    }

    /// LM Studio and Ollama accept any credential. A LiteLLM proxy issues virtual keys and
    /// answers 401 without one.
    public var requiresKey: Bool {
        switch self {
        case .lmStudio, .ollama: false
        case .liteLLM, .custom: true
        }
    }

    /// What goes into `ANTHROPIC_AUTH_TOKEN` when the server needs no key.
    ///
    /// It cannot be left empty: with a base URL set and no token of its own, Claude Code falls
    /// back to the subscription's OAuth credential and sends *that* to the local server. A
    /// placeholder keeps the Anthropic credential on the Anthropic side.
    public var placeholderToken: String? {
        switch self {
        case .lmStudio: "lmstudio"
        case .ollama: "ollama"
        case .liteLLM, .custom: nil
        }
    }

    /// Model ids on these servers are opaque local names, so there is no reason to expect
    /// "claude" in them — and no reason to warn that there is not.
    public var expectsClaudeLikeIDs: Bool {
        switch self {
        case .lmStudio, .ollama: false
        case .liteLLM, .custom: true
        }
    }

    public var baseURLHelp: String {
        switch self {
        case .lmStudio:
            "LM Studio's server, normally http://127.0.0.1:1234. Its Anthropic-compatible "
                + "/v1/messages route is what Claude Code calls."
        case .liteLLM:
            "The proxy's address with its port, normally :4000 — not the model server behind it, "
                + "which has no /v1/messages route."
        case .ollama:
            "Ollama's server, normally http://127.0.0.1:11434. Needs an Ollama release with the "
                + "Anthropic-compatible /v1/messages route."
        case .custom:
            "Any server that answers the Anthropic Messages API, streamed, on /v1/messages."
        }
    }
}
