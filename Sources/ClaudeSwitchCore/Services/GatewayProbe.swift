import Foundation

/// Verifies a profile end to end before the user commits to it.
///
/// Two checks, because they fail independently and for different reasons: `/v1/models` proves
/// the key is valid and tells us which aliases exist; `/v1/messages` proves the Anthropic route
/// answers. The second is the one that matters — it is the route Claude Code uses and the one
/// vLLM does not have.
public enum GatewayProbe {
    public struct Result {
        public var reachable: Bool
        public var publishedModels: [String]
        public var messagesRouteOK: Bool
        public var latency: Duration?
        public var findings: [Warning]

        /// Green only when a real turn completed. Publishing a name proves nothing about serving it.
        public var isHealthy: Bool { reachable && messagesRouteOK }
    }

    public static func run(profile: Profile, authToken: String, timeout: TimeInterval = 8) async -> Result {
        var result = Result(reachable: false, publishedModels: [], messagesRouteOK: false,
                            latency: nil, findings: [])

        guard let base = URL(string: profile.baseURL) else {
            result.findings.append(Warning(severity: .blocking, message: "Base URL is not a valid URL."))
            return result
        }
        guard !authToken.isEmpty else {
            result.findings.append(Warning(severity: .blocking, message:
                "No key saved for this profile. The gateway answers 401 without one."))
            return result
        }

        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            return config
        }())

        // 1 — the alias list, straight from the gateway. config.yaml is not readable to us.
        do {
            var request = URLRequest(url: base.appending(path: "v1/models"))
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            result.reachable = true

            if code == 401 {
                result.findings.append(Warning(severity: .blocking, message:
                    "401 from the gateway — the key is missing, wrong, or expired. Keys are issued "
                    + "with a duration."))
                return result
            }
            guard code == 200 else {
                result.findings.append(Warning(severity: .blocking, message:
                    "/v1/models returned HTTP \(code)."))
                return result
            }

            result.publishedModels = parseModelIDs(data)
            result.findings.append(contentsOf: checkAliases(profile: profile,
                                                            published: result.publishedModels))
        } catch {
            result.findings.append(Warning(severity: .blocking, message:
                "Cannot reach \(profile.baseURL): \(error.localizedDescription)"))
            return result
        }

        // 2 — a real turn on the Anthropic route.
        do {
            var request = URLRequest(url: base.appending(path: "v1/messages"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": profile.model,
                "max_tokens": 16,
                "messages": [["role": "user", "content": "reply with the word ok"]],
            ])

            let clock = ContinuousClock()
            let start = clock.now
            let (data, response) = try await session.data(for: request)
            result.latency = clock.now - start
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            switch code {
            case 200:
                result.messagesRouteOK = true
            case 404:
                result.findings.append(Warning(severity: .blocking, message:
                    "404 on /v1/messages. This is vLLM or a plain OpenAI endpoint, not a gateway "
                    + "that speaks the Anthropic API. Claude Code cannot use it."))
            case 500:
                result.findings.append(Warning(severity: .blocking, message:
                    "500 on the first turn — the signature of an effort level Qwen3.8 rejects. "
                    + "Set effort to low, medium or xhigh."))
            case 403:
                result.findings.append(Warning(severity: .blocking, message:
                    "403 — your key is not scoped to '\(profile.model)'."))
            default:
                let body = String(data: data.prefix(240), encoding: .utf8) ?? ""
                result.findings.append(Warning(severity: .blocking, message:
                    "/v1/messages returned HTTP \(code). \(body)"))
            }
        } catch {
            result.findings.append(Warning(severity: .blocking, message:
                "/v1/messages failed: \(error.localizedDescription)"))
        }

        return result
    }

    /// A liveness ping for the menu's status line. No key needed, so it can run on a timer.
    public static func liveness(baseURL: String, timeout: TimeInterval = 4) async -> Bool {
        guard let base = URL(string: baseURL) else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        var request = URLRequest(url: base.appending(path: "health/liveliness"))
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession(configuration: config).data(for: request)
        else { return false }
        // Any answer at all means something is listening; 401 still proves reachability.
        return (response as? HTTPURLResponse) != nil
    }

    private static func parseModelIDs(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    private static func checkAliases(profile: Profile, published: [String]) -> [Warning] {
        guard !published.isEmpty else { return [] }
        var out: [Warning] = []
        var seen = Set<String>()

        for (label, id) in [("Model", profile.model), ("Haiku", profile.haikuModel),
                            ("Sonnet", profile.sonnetModel), ("Opus", profile.opusModel)] {
            guard !published.contains(id), seen.insert(id).inserted else { continue }
            out.append(Warning(severity: .blocking, message:
                "\(label) model '\(id)' is not published by this gateway. Available: "
                + published.joined(separator: ", ")))
        }

        if published.contains("triage-agent") {
            out.append(Warning(severity: .caution, message:
                "This gateway serves triage-agent — a production tool with real execution ability "
                + "against stores. Developer keys are scoped to exclude it; do not call it."))
        }

        return out
    }
}
