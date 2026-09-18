import Foundation

/// Verifies a destination end to end before the user commits to it.
///
/// The checks fail independently and for different reasons, so each is its own step:
///
/// 1. **Listing** — the server answers, the key is accepted, and the chosen model exists (and,
///    on LM Studio, is the loaded instance rather than one it would load a second copy of).
/// 2. **Limits** — the context window plus the output ceiling fits inside what the server
///    really enforces. Getting this wrong is what makes a long session hang.
/// 3. **Turn** — a real non-streamed reply on `/v1/messages`.
/// 4. **Stream** — the same route with `stream: true`, asking for the profile's *actual* output
///    ceiling. Claude Code only ever streams, and it sends that ceiling on every turn.
/// 5. **Tools** — the model answers with a `tool_use` block. Claude Code is a tool loop; a model
///    that only ever writes prose cannot drive it.
/// 6. **Request shape** — a `role: "system"` message inside `messages`, which Claude Code 2.1.200
///    sends for any model it does not recognise when the base URL is custom. vLLM's Anthropic
///    endpoint rejects it with a 400 that Claude Code's own fallback does not recognise, so every
///    turn fails even though the five checks above pass.
public enum GatewayProbe {
    public struct Step: Identifiable, Hashable {
        public enum State: Hashable { case passed, warned, failed, skipped }
        public var id: String { name }
        public let name: String
        public var state: State
        public var detail: String
    }

    public struct Result {
        public var reachable: Bool
        public var publishedModels: [String]
        public var messagesRouteOK: Bool
        public var streamingRouteOK: Bool
        public var toolUseOK: Bool?
        /// Whether the server takes `role: "system"` inside `messages`. nil when not checked.
        public var midConversationSystemOK: Bool?
        public var serverLength: Int?
        public var latency: Duration?
        public var findings: [Warning]
        public var steps: [Step] = []

        public init(reachable: Bool, publishedModels: [String], messagesRouteOK: Bool,
                    streamingRouteOK: Bool, toolUseOK: Bool? = nil, serverLength: Int? = nil,
                    latency: Duration?, findings: [Warning]) {
            self.reachable = reachable
            self.publishedModels = publishedModels
            self.messagesRouteOK = messagesRouteOK
            self.streamingRouteOK = streamingRouteOK
            self.toolUseOK = toolUseOK
            self.serverLength = serverLength
            self.latency = latency
            self.findings = findings
        }

        /// Green only when a real *streamed* turn completed with well-formed events and nothing
        /// blocking was found along the way. Publishing a name proves nothing about serving it,
        /// and a good non-streamed turn proves nothing about the route Claude Code calls.
        public var isHealthy: Bool {
            reachable && messagesRouteOK && streamingRouteOK
                && !findings.contains { $0.severity == .blocking }
        }

        mutating func record(_ name: String, _ state: Step.State, _ detail: String) {
            steps.append(Step(name: name, state: state, detail: detail))
        }
    }

    /// How long a turn may take. A thinking model on a cold server can spend a while before its
    /// first token; eight seconds failed healthy local servers.
    public static let turnTimeout: TimeInterval = 90

    public static func run(profile: Profile, authToken: String?,
                           timeout: TimeInterval = turnTimeout) async -> Result {
        var result = Result(reachable: false, publishedModels: [], messagesRouteOK: false,
                            streamingRouteOK: false, latency: nil, findings: [])

        // Turns go where Claude Code's turns will go — through the relay when it is on — so the
        // checks prove the path that will actually be used. Discovery asks the server itself.
        guard let base = URL(string: profile.clientBaseURL), base.host != nil else {
            result.findings.append(Warning(severity: .blocking, message: "Base URL is not a valid URL."))
            return result
        }
        let token = profile.effectiveToken(savedKey: authToken)
        guard let token else {
            result.findings.append(Warning(severity: .blocking, message:
                "No key saved for this destination. \(profile.provider.displayName) answers 401 without one."))
            return result
        }
        guard !DestinationDiscovery.neverProbe.contains(profile.model) else {
            result.findings.append(Warning(severity: .blocking, message:
                "'\(profile.model)' is a production tool, not a chat model. ClaudeSwitch will not send it a request."))
            return result
        }

        // 1 — listing
        let listing = await DestinationDiscovery.discover(provider: profile.provider,
                                                          baseURL: profile.baseURL, token: token)
        result.publishedModels = listing.models.map(\.id)
        let listingBlocked = listing.findings.filter { $0.severity == .blocking }
        if !listingBlocked.isEmpty && listing.models.isEmpty {
            result.findings.append(contentsOf: listingBlocked)
            result.record("Listing", .failed, listingBlocked.map(\.message).joined(separator: " "))
            // An unreachable server has nothing more to say; a 404 listing might still serve turns.
            if listingBlocked.contains(where: { $0.message.hasPrefix("Cannot reach") || $0.message.hasPrefix("401") }) {
                return result
            }
        } else {
            result.reachable = true
            let aliasFindings = checkAliases(profile: profile, listing: listing)
            result.findings.append(contentsOf: aliasFindings)
            result.record("Listing",
                          aliasFindings.contains { $0.severity == .blocking } ? .failed : .passed,
                          aliasFindings.first?.message
                              ?? "\(listing.selectableModels.count) usable model\(listing.selectableModels.count == 1 ? "" : "s"); '\(profile.model)' is among them.")
        }

        // 2 — limits
        let length = await DestinationDiscovery.serverLength(provider: profile.provider,
                                                             baseURL: profile.baseURL, token: token,
                                                             model: profile.model, listing: listing)
        result.serverLength = length
        if let length {
            if let problem = LimitPlan.problem(modelLength: length, compactWindow: profile.contextWindow,
                                               maxOutputTokens: profile.maxOutputTokens) {
                result.findings.append(Warning(severity: .blocking, message: problem))
                result.record("Limits", .failed, problem)
            } else {
                if profile.modelLength != 0, profile.modelLength != length {
                    result.findings.append(Warning(severity: .caution, message:
                        "The server now enforces \(length.formatted()) tokens; this profile was set up for "
                        + "\(profile.modelLength.formatted()). The limits still fit, but re-run Discover to use it fully."))
                }
                result.record("Limits", .passed,
                              "Window \(profile.contextWindow.formatted()) + output \(profile.maxOutputTokens.formatted()) "
                              + "fits the server's \(length.formatted()).")
            }
        } else {
            result.findings.append(Warning(severity: .caution, message:
                "Could not read this server's context length, so the window could not be checked against it."))
            result.record("Limits", .warned, "Server length unknown — not checked.")
        }

        let client = HTTPClient(base: base, token: token, timeout: timeout)

        // 3 — a real turn
        let clock = ContinuousClock()
        let start = clock.now
        let turn = await client.post("v1/messages", json: [
            "model": profile.model,
            "max_tokens": min(2_048, max(profile.maxOutputTokens, 256)),
            "messages": [["role": "user", "content": "Reply with exactly the word: ok"]],
        ])
        switch turn {
        case .success(200, let data):
            result.latency = clock.now - start
            result.reachable = true
            result.messagesRouteOK = true
            let summary = summarizeMessage(data)
            if summary.textCharacters == 0, summary.stopReason == "max_tokens" {
                result.findings.append(Warning(severity: .caution, message:
                    "The model spent the whole test budget thinking and wrote no reply. The route works, "
                    + "but keep max output generous — reasoning counts towards it."))
                result.record("Turn", .warned, "Answered, but only with thinking.")
            } else {
                result.record("Turn", .passed, "Answered in \(result.latency.map(milliseconds) ?? 0) ms.")
            }
        case .success(let code, let data):
            let finding = turnFailure(code: code, body: data, profile: profile)
            result.findings.append(finding)
            result.record("Turn", .failed, finding.message)
        case .failure(let message):
            let finding = Warning(severity: .blocking, message: "/v1/messages failed: \(message)")
            result.findings.append(finding)
            result.record("Turn", .failed, finding.message)
        }

        guard result.messagesRouteOK else {
            for step in ["Stream", "Tools", "Request shape"] {
                result.record(step, .skipped, "Skipped — the plain turn failed.")
            }
            return result
        }

        // 4 — the same route, streamed, at the real output ceiling
        let stream = await client.post("v1/messages", json: [
            "model": profile.model,
            "max_tokens": max(profile.maxOutputTokens, 1),
            "stream": true,
            "messages": [["role": "user", "content": "Count: one two three"]],
        ])
        switch stream {
        case .success(200, let data):
            let findings = checkSSE(String(decoding: data, as: UTF8.self), into: &result)
            result.findings.append(contentsOf: findings)
            let state: Step.State = !result.streamingRouteOK ? .failed : findings.isEmpty ? .passed : .warned
            result.record("Stream", state, findings.first?.message
                          ?? "Well-formed at max_tokens \(profile.maxOutputTokens.formatted()).")
        case .success(let code, let data):
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            var message = "Streamed /v1/messages returned HTTP \(code) at max_tokens "
                + "\(profile.maxOutputTokens.formatted()), while a smaller plain turn succeeded. "
                + "Claude Code sends this ceiling on every turn."
            if let limit = DestinationDiscovery.parseLengthFromError(body) {
                message += " The server's ceiling is \(limit.formatted()) — lower max output."
            } else {
                message += " \(body)"
            }
            result.findings.append(Warning(severity: .blocking, message: message))
            result.record("Stream", .failed, message)
        case .failure(let message):
            let finding = Warning(severity: .blocking, message: "Streamed /v1/messages failed: \(message)")
            result.findings.append(finding)
            result.record("Stream", .failed, finding.message)
        }

        // 5 — tool use
        let tools = await client.post("v1/messages", json: [
            "model": profile.model,
            "max_tokens": min(4_096, max(profile.maxOutputTokens, 512)),
            "tools": [[
                "name": "get_time",
                "description": "Returns the current time.",
                "input_schema": ["type": "object", "properties": [String: Any]()],
            ]],
            "messages": [["role": "user", "content": "What time is it? Call the get_time tool."]],
        ])
        if case .success(200, let data) = tools {
            let summary = summarizeMessage(data)
            result.toolUseOK = summary.toolUses > 0
            if summary.toolUses > 0 {
                result.record("Tools", .passed, "Called the tool.")
            } else {
                let finding = Warning(severity: .caution, message:
                    "Asked to call a tool, the model replied in prose. Claude Code works by calling tools; "
                    + "check the server's tool-call parser for this model.")
                result.findings.append(finding)
                result.record("Tools", .warned, finding.message)
            }
        } else {
            result.toolUseOK = false
            let finding = Warning(severity: .caution, message:
                "A request with tools attached was refused. Claude Code always attaches tools.")
            result.findings.append(finding)
            result.record("Tools", .warned, finding.message)
        }

        // 6 — the request shape Claude Code actually sends
        let shaped = await client.post("v1/messages", json: [
            "model": profile.model,
            "max_tokens": min(2_048, max(profile.maxOutputTokens, 256)),
            "system": "You are terse.",
            "messages": [
                ["role": "user", "content": "Reply with exactly the word: ok"],
                ["role": "system", "content": "Context added mid-conversation."],
            ],
        ])
        switch shaped {
        case .success(200, _):
            result.midConversationSystemOK = true
            result.record("Request shape", .passed, "Accepts the system messages Claude Code places inside the conversation.")
        case .success(let code, let data):
            result.midConversationSystemOK = false
            let body = String(decoding: data.prefix(600), as: UTF8.self)
            let rejectsRole = body.contains("system") && (body.contains("role") || body.contains("literal_error"))
            let message = rejectsRole
                ? "The server rejects a role: \"system\" message inside messages (HTTP \(code)). Claude Code "
                    + "sends one on every turn to a model it does not recognise, and this rejection is not one "
                    + "its fallback detects — so every session fails with an API error even though the checks "
                    + "above pass. Turn on the compatibility relay for this destination, or fold system "
                    + "messages into the first user turn on the server (for vLLM's Anthropic endpoint, a "
                    + "LiteLLM pre-call hook)."
                : "A request carrying a mid-conversation system message returned HTTP \(code). \(body.prefix(240))"
            result.findings.append(Warning(severity: .blocking, message: message))
            result.record("Request shape", .failed, message)
        case .failure(let message):
            result.findings.append(Warning(severity: .caution, message: "Request-shape check failed: \(message)"))
            result.record("Request shape", .warned, message)
        }

        return result
    }

    // MARK: - Pieces

    /// The SSE contract Claude Code enforces: every `content_block_start` is matched by a
    /// `content_block_stop`, and the message is terminated. An unclosed block is *discarded* —
    /// usage and `stop_reason` survive the turn, the text does not.
    ///
    /// A terminated stream with no text is well-formed: the route works and the model spent its
    /// budget thinking. That is worth a caution, not a refusal — refusing it is what used to turn
    /// a healthy local server away.
    static func checkSSE(_ body: String, into result: inout Result) -> [Warning] {
        var counts: [String: Int] = [:]
        for line in body.split(separator: "\n", omittingEmptySubsequences: true)
        where line.hasPrefix("event:") {
            let name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            counts[name, default: 0] += 1
        }

        guard !counts.isEmpty else {
            return [Warning(severity: .blocking, message:
                "The streamed response carried no SSE events at all. This is not an Anthropic "
                + "Messages stream.")]
        }

        let started = counts["content_block_start"] ?? 0
        let stopped = counts["content_block_stop"] ?? 0
        let deltas = counts["content_block_delta"] ?? 0

        if started > stopped {
            return [Warning(severity: .blocking, message:
                "The server's streaming adapter opened \(started) content block"
                + (started == 1 ? "" : "s") + " and closed \(stopped). The Anthropic SSE contract "
                + "requires one content_block_stop per content_block_start, and Claude Code "
                + "discards any block left open — so every reply arrives blank even though the "
                + "turn succeeds and tokens are billed. No client-side option works around it. "
                + "Usually the gateway is translating /v1/messages into some other API instead of "
                + "passing it through to a backend that speaks Anthropic natively. Check whether "
                + "the gateway publishes a model id that is configured for passthrough — in "
                + "LiteLLM that is supported_endpoints including \"/v1/messages\" on the alias — "
                + "and select that id rather than the backend's raw model name.")]
        }

        if counts["message_stop"] == nil {
            return [Warning(severity: .blocking, message:
                "The stream never sent message_stop, so Claude Code cannot tell a finished turn "
                + "from a dropped connection.")]
        }

        result.streamingRouteOK = true

        if deltas == 0 {
            return [Warning(severity: .caution, message:
                "The streamed turn emitted no text. The stream is well-formed, so this is the model "
                + "spending its budget on thinking — keep max output generous.")]
        }
        return []
    }

    struct MessageSummary: Equatable {
        var textCharacters = 0
        var toolUses = 0
        var stopReason: String?
    }

    static func summarizeMessage(_ data: Data) -> MessageSummary {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MessageSummary()
        }
        var summary = MessageSummary(stopReason: root["stop_reason"] as? String)
        for block in root["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text": summary.textCharacters += (block["text"] as? String)?.count ?? 0
            case "tool_use": summary.toolUses += 1
            default: break
            }
        }
        return summary
    }

    static func turnFailure(code: Int, body: Data, profile: Profile) -> Warning {
        let text = String(decoding: body.prefix(400), as: UTF8.self)
        switch code {
        case 401:
            return Warning(severity: .blocking, message:
                "401 — the key is missing, wrong, or expired.")
        case 403:
            return Warning(severity: .blocking, message:
                "403 — your key is not scoped to '\(profile.model)'.")
        case 404:
            return Warning(severity: .blocking, message:
                "404 on /v1/messages. This server does not speak the Anthropic Messages API "
                + (profile.provider == .ollama ? "— Ollama added it in 0.14; update Ollama." :
                   profile.provider == .lmStudio ? "— update LM Studio." :
                   "— it is a model server or a plain OpenAI endpoint, not an Anthropic-compatible one.")
                + " Claude Code cannot use it.")
        case 500 where text.localizedCaseInsensitiveContains("effort")
            || text.localizedCaseInsensitiveContains("reasoning"):
            return Warning(severity: .blocking, message:
                "500 on the first turn, mentioning effort/reasoning — set effort to low, medium or xhigh.")
        default:
            return Warning(severity: .blocking, message: "/v1/messages returned HTTP \(code). \(text)")
        }
    }

    static func checkAliases(profile: Profile, listing: DestinationDiscovery.Result) -> [Warning] {
        guard !listing.models.isEmpty else { return [] }
        var out: [Warning] = []
        var seen = Set<String>()
        let byID = Dictionary(listing.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (label, id) in [("Model", profile.model), ("Haiku", profile.haikuModel),
                            ("Sonnet", profile.sonnetModel), ("Opus", profile.opusModel)] {
            guard seen.insert(id).inserted else { continue }
            guard let model = byID[id] else {
                out.append(Warning(severity: .blocking, message:
                    "\(label) model '\(id)' is not served here. Available: "
                    + listing.selectableModels.map(\.id).joined(separator: ", ")))
                continue
            }
            if model.isLoaded == false {
                out.append(Warning(severity: .blocking, message:
                    "\(label) model '\(id)' is not loaded. Asking for it would make "
                    + "\(profile.provider == .lmStudio ? "LM Studio" : "the server") load another copy. "
                    + "Pick the loaded instance: " + listing.selectableModels.map(\.id).joined(separator: ", ")))
            } else if !model.isChatModel {
                out.append(Warning(severity: .blocking, message: "\(label) model '\(id)' is not a chat model."))
            }
        }
        return out
    }

    // MARK: - Liveness

    public enum Liveness: Equatable {
        case up
        case down(String)
        /// The server answers, but the chosen model is not ready to serve.
        case degraded(String)

        public var isUp: Bool { self == .up }
    }

    /// A cheap check for the menu's status line, safe to run on a timer. It never generates.
    public static func liveness(profile: Profile, authToken: String?, timeout: TimeInterval = 4) async -> Liveness {
        guard let base = URL(string: profile.baseURL), base.host != nil else { return .down("invalid base URL") }
        let client = HTTPClient(base: base, token: profile.effectiveToken(savedKey: authToken), timeout: timeout)

        switch profile.provider {
        case .lmStudio:
            guard case .success(200, let data) = await client.get("api/v0/models") else {
                return await plainLiveness(client, path: "v1/models", what: "LM Studio")
            }
            let models = DestinationDiscovery.parseLMStudio(data)
            guard let model = models.first(where: { $0.id == profile.model }) else {
                return .degraded("'\(profile.model)' is not in LM Studio")
            }
            return model.isLoaded == false ? .degraded("'\(profile.model)' is not loaded") : .up
        case .ollama:
            return await plainLiveness(client, path: "api/version", what: "Ollama")
        case .liteLLM:
            return await plainLiveness(client, path: "health/liveliness", what: "the proxy")
        case .custom:
            return await plainLiveness(client, path: "v1/models", what: "the server")
        }
    }

    private static func plainLiveness(_ client: HTTPClient, path: String, what: String) async -> Liveness {
        switch await client.get(path) {
        // Any HTTP answer means something is listening; 401 still proves reachability.
        case .success: .up
        case .failure(let message): .down("\(what) is not answering: \(message)")
        }
    }

    public static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1000 + Int(Double(duration.components.attoseconds) / 1e15)
    }
}
