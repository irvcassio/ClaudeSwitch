import Foundation

/// Asks a destination what it can serve, so the user picks from a list instead of typing ids.
///
/// Each kind of server answers the question differently, and the difference is the context
/// length — the number that decides whether a long session works or wedges:
///
/// * **LM Studio** reports each model's state and the context its *loaded instance* was started
///   with. Only a loaded instance is safe to pick: asking for any other id makes LM Studio load
///   another full copy of the weights.
/// * **Ollama** serves at `num_ctx`, which is usually far smaller than the architecture's limit.
///   A loaded model reports its real length; otherwise the model's own parameters are read.
/// * **LiteLLM** publishes a model's input limit but not the server's ceiling, so the ceiling is
///   *measured*: an oversized `max_tokens` is refused before generation, and the refusal states
///   the limit.
public enum DestinationDiscovery {
    public struct Model: Identifiable, Hashable {
        public var id: String
        /// The length the server will actually enforce, when known.
        public var contextLength: Int?
        /// The architecture's maximum, shown for reference only.
        public var architectureMaximum: Int?
        public var serverMaxOutput: Int?
        /// nil when the server does not say.
        public var isLoaded: Bool?
        /// False for embeddings and anything else Claude Code cannot hold a conversation with.
        public var isChatModel: Bool
        public var detail: String?

        public init(id: String, contextLength: Int? = nil, architectureMaximum: Int? = nil,
                    serverMaxOutput: Int? = nil, isLoaded: Bool? = nil, isChatModel: Bool = true,
                    detail: String? = nil) {
            self.id = id
            self.contextLength = contextLength
            self.architectureMaximum = architectureMaximum
            self.serverMaxOutput = serverMaxOutput
            self.isLoaded = isLoaded
            self.isChatModel = isChatModel
            self.detail = detail
        }

        /// Whether picking this model is safe as-is.
        public var isSelectable: Bool { isChatModel && isLoaded != false }

        public var summary: String {
            var parts: [String] = []
            if let contextLength { parts.append("\(contextLength.formatted()) ctx") }
            if isLoaded == true { parts.append("loaded") }
            if isLoaded == false { parts.append("not loaded") }
            if !isChatModel { parts.append("not a chat model") }
            return parts.joined(separator: " · ")
        }
    }

    public struct Result {
        public var models: [Model] = []
        public var findings: [Warning] = []

        public var selectableModels: [Model] { models.filter(\.isSelectable) }
    }

    /// Model ids a discovery must never send a request to. `triage-agent` is a production tool
    /// with real execution ability; listing it is fine, calling it is not.
    public static let neverProbe: Set<String> = ["triage-agent"]

    // MARK: - Listing

    public static func discover(provider: Provider, baseURL: String, token: String?,
                                timeout: TimeInterval = 10) async -> Result {
        guard let base = URL(string: baseURL), base.host != nil else {
            return Result(findings: [Warning(severity: .blocking, message: "Base URL is not a valid URL.")])
        }
        let client = HTTPClient(base: base, token: token, timeout: timeout)

        switch provider {
        case .lmStudio: return await discoverLMStudio(client)
        case .ollama: return await discoverOllama(client)
        case .liteLLM: return await discoverLiteLLM(client)
        case .custom: return await discoverOpenAIList(client)
        }
    }

    private static func discoverLMStudio(_ client: HTTPClient) async -> Result {
        switch await client.get("api/v0/models") {
        case .success(200, let data):
            var result = Result(models: parseLMStudio(data))
            if result.models.contains(where: { $0.isLoaded == false && $0.isChatModel }) {
                result.findings.append(Warning(severity: .caution, message:
                    "Models marked “not loaded” are hidden from the picker: asking LM Studio for one "
                    + "loads another full copy of its weights. Whatever pins your model (Doppo Console, "
                    + "or lms load --identifier) decides what is loaded."))
            }
            if result.selectableModels.isEmpty {
                result.findings.append(Warning(severity: .blocking, message:
                    "LM Studio is running but has no chat model loaded. Load one first — ClaudeSwitch "
                    + "reads LM Studio's state and never loads models itself."))
            }
            return result
        case .success(let code, _):
            // Older LM Studio builds have no native API; the OpenAI list still names the models.
            var result = await discoverOpenAIList(client)
            result.findings.append(Warning(severity: .caution, message:
                "LM Studio's native API answered HTTP \(code), so load state and context length are "
                + "unknown. Update LM Studio, or enter the loaded context length by hand."))
            return result
        case .failure(let message):
            return Result(findings: [unreachable("LM Studio", client, message)])
        }
    }

    private static func discoverOllama(_ client: HTTPClient) async -> Result {
        guard case .success(200, let tagsData) = await client.get("api/tags") else {
            return Result(findings: [Warning(severity: .blocking, message:
                "Cannot list Ollama's models at \(client.base.absoluteString)/api/tags. Is Ollama running?")])
        }
        var models = parseOllamaTags(tagsData)
        var loaded: [String: Int?] = [:]
        if case .success(200, let psData) = await client.get("api/ps") {
            loaded = parseOllamaPS(psData)
        }
        for index in models.indices {
            let name = models[index].id
            if case .success(200, let showData) = await client.post("api/show", json: ["model": name]) {
                let show = parseOllamaShow(showData)
                models[index].architectureMaximum = show.architectureMaximum
                models[index].isChatModel = show.isChatModel
                models[index].contextLength = show.numCtx
            }
            if let entry = loaded[name] {
                models[index].isLoaded = true
                if let length = entry { models[index].contextLength = length }
            }
            if models[index].contextLength == nil {
                models[index].detail = "Served at Ollama's default num_ctx, which is usually far below "
                    + "the model's maximum. Set num_ctx (or OLLAMA_CONTEXT_LENGTH) and load it to confirm."
            }
        }
        return Result(models: models)
    }

    private static func discoverLiteLLM(_ client: HTTPClient) async -> Result {
        var result = await discoverOpenAIList(client)
        guard result.findings.allSatisfy({ $0.severity != .blocking }) else { return result }

        if case .success(200, let data) = await client.get("v1/model/info") {
            let info = parseLiteLLMInfo(data)
            for index in result.models.indices {
                guard let entry = info[result.models[index].id] else { continue }
                result.models[index].architectureMaximum = entry.maxInput
                result.models[index].serverMaxOutput = entry.maxOutput
                if entry.isEmbedding { result.models[index].isChatModel = false }
            }
        }
        for index in result.models.indices where result.models[index].id.contains("embedding") {
            result.models[index].isChatModel = false
        }
        for index in result.models.indices where neverProbe.contains(result.models[index].id) {
            result.models[index].isChatModel = false
            result.models[index].detail = "A production tool with real execution ability — not a chat model."
        }
        return result
    }

    private static func discoverOpenAIList(_ client: HTTPClient) async -> Result {
        switch await client.get("v1/models") {
        case .success(200, let data):
            let ids = parseOpenAIModelIDs(data)
            var result = Result(models: ids.map { Model(id: $0) })
            if ids.isEmpty {
                result.findings.append(Warning(severity: .blocking, message:
                    "The server answered /v1/models with no models."))
            }
            return result
        case .success(401, _):
            return Result(findings: [Warning(severity: .blocking, message:
                "401 — the key is missing, wrong, or expired.")])
        case .success(let code, let data):
            if let scheme = schemeMismatch(client, code: code, body: data) {
                return Result(findings: [scheme])
            }
            return Result(findings: [Warning(severity: .blocking, message:
                "/v1/models returned HTTP \(code). Enter the model id by hand if this server does not list models.")])
        case .failure(let message):
            return Result(findings: [unreachable("the server", client, message)])
        }
    }

    // MARK: - Measuring

    /// The server's ceiling on prompt + output for `model`, read from the refusal of an oversized
    /// request. nil when the server does not refuse — LM Studio clamps instead, and so does a
    /// LiteLLM proxy running aiserver's Claude Code compatibility hook — or does not say.
    public static func measureLength(baseURL: String, token: String?, model: String,
                                     timeout: TimeInterval = 30) async -> Int? {
        guard !neverProbe.contains(model), let base = URL(string: baseURL) else { return nil }
        let client = HTTPClient(base: base, token: token, timeout: timeout)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 50_000_000,
            "messages": [["role": "user", "content": "Reply with exactly: ok"]],
        ]
        guard case .success(let code, let data) = await client.post("v1/messages", json: body),
              code != 200
        else { return nil }
        return parseLengthFromError(String(decoding: data, as: UTF8.self))
    }

    /// The length for the chosen model, from whichever source this provider has.
    public static func serverLength(provider: Provider, baseURL: String, token: String?,
                                    model: String, listing: Result? = nil) async -> Int? {
        let listed = listing?.models.first { $0.id == model }
        switch provider {
        case .lmStudio, .ollama:
            if let length = listed?.contextLength { return length }
            let fresh = await discover(provider: provider, baseURL: baseURL, token: token)
            return fresh.models.first { $0.id == model }?.contextLength
        case .liteLLM, .custom:
            if let measured = await measureLength(baseURL: baseURL, token: token, model: model) {
                return measured
            }
            // Not refused — the server clamps (LM Studio, or a proxy with a compatibility hook).
            // The published input limit is then the best answer the server gives.
            if let published = listed?.architectureMaximum { return published }
            guard listing == nil else { return nil }
            let fresh = await discover(provider: provider, baseURL: baseURL, token: token)
            return fresh.models.first { $0.id == model }?.architectureMaximum
        }
    }

    // MARK: - Parsing

    static func parseLMStudio(_ data: Data) -> [Model] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let type = entry["type"] as? String ?? "llm"
            let loaded = (entry["state"] as? String).map { $0 == "loaded" }
            let loadedLength = entry["loaded_context_length"] as? Int
            let maximum = entry["max_context_length"] as? Int
            var model = Model(id: id,
                              contextLength: loaded == true ? (loadedLength ?? maximum) : loadedLength,
                              architectureMaximum: maximum,
                              isLoaded: loaded,
                              isChatModel: type == "llm" || type == "vlm")
            if loaded == false, model.isChatModel {
                model.detail = "Not loaded. Picking it would make LM Studio load another copy."
            }
            return model
        }
        .sorted { ($0.isSelectable ? 0 : 1, $0.id) < ($1.isSelectable ? 0 : 1, $1.id) }
    }

    static func parseOllamaTags(_ data: Data) -> [Model] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["models"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { ($0["name"] as? String ?? $0["model"] as? String).map { Model(id: $0) } }
            .sorted { $0.id < $1.id }
    }

    /// Loaded model name → the context length it was loaded with, when the server says.
    static func parseOllamaPS(_ data: Data) -> [String: Int?] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["models"] as? [[String: Any]]
        else { return [:] }
        var out: [String: Int?] = [:]
        for entry in list {
            guard let name = entry["name"] as? String ?? entry["model"] as? String else { continue }
            out[name] = entry["context_length"] as? Int
        }
        return out
    }

    struct OllamaShow: Equatable {
        var numCtx: Int?
        var architectureMaximum: Int?
        var isChatModel: Bool
    }

    static func parseOllamaShow(_ data: Data) -> OllamaShow {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OllamaShow(numCtx: nil, architectureMaximum: nil, isChatModel: true)
        }
        var numCtx: Int?
        if let parameters = root["parameters"] as? String {
            for line in parameters.split(separator: "\n") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2, parts[0] == "num_ctx", let value = Int(parts[1]) { numCtx = value }
            }
        }
        var maximum: Int?
        if let info = root["model_info"] as? [String: Any] {
            maximum = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
        }
        var isChat = true
        if let capabilities = root["capabilities"] as? [String] {
            isChat = capabilities.contains("completion")
        }
        return OllamaShow(numCtx: numCtx, architectureMaximum: maximum, isChatModel: isChat)
    }

    struct LiteLLMInfo: Equatable {
        var maxInput: Int?
        var maxOutput: Int?
        var isEmbedding: Bool
    }

    static func parseLiteLLMInfo(_ data: Data) -> [String: LiteLLMInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]]
        else { return [:] }
        var out: [String: LiteLLMInfo] = [:]
        for entry in list {
            guard let name = entry["model_name"] as? String else { continue }
            let info = entry["model_info"] as? [String: Any] ?? [:]
            func int(_ key: String) -> Int? {
                if let value = info[key] as? Int { return value }
                if let value = info[key] as? Double { return Int(value) }
                return nil
            }
            out[name] = LiteLLMInfo(maxInput: int("max_input_tokens"),
                                    maxOutput: int("max_output_tokens"),
                                    isEmbedding: (info["mode"] as? String) == "embedding")
        }
        return out
    }

    static func parseOpenAIModelIDs(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    /// Reads the ceiling out of a refusal. vLLM states it two ways depending on which check
    /// fired; a proxy wraps either in its own error text, with the quotes escaped.
    static func parseLengthFromError(_ body: String) -> Int? {
        let text = body.replacingOccurrences(of: "\\", with: "")
        let patterns = [
            #"max_model_len\s*=\s*(?:max_total_tokens\s*=\s*)?(\d+)"#,
            #"maximum context length is (\d+)"#,
            #"context length of only (\d+)"#,
            #"n_ctx(?:_slot)?\s*[=:]\s*(\d+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let value = Int(text[range]), value > 0
            else { continue }
            return value
        }
        return nil
    }

    /// A TLS port asked for in plain `http://`. nginx answers this with a 400 whose body says so,
    /// and the generic "enter the model id by hand" advice is actively wrong here: the id is fine,
    /// the scheme is not, and every turn would fail the same way after typing one in.
    static func schemeMismatch(_ client: HTTPClient, code: Int, body: Data) -> Warning? {
        guard code == 400, client.base.scheme?.lowercased() == "http" else { return nil }
        let text = String(decoding: body, as: UTF8.self).lowercased()
        guard text.contains("plain http request was sent to https port")
                || text.contains("http request was sent to https port")
        else { return nil }
        var https = URLComponents(url: client.base, resolvingAgainstBaseURL: false)
        https?.scheme = "https"
        let corrected = https?.string ?? client.base.absoluteString
        return Warning(severity: .blocking, message:
            "This port speaks HTTPS, and the Base URL asks for it in plain HTTP — that is what the "
            + "400 means. Use \(corrected) instead. The model id is not the problem; typing one by "
            + "hand would leave every turn failing the same way.")
    }

    private static func unreachable(_ what: String, _ client: HTTPClient, _ message: String) -> Warning {
        Warning(severity: .blocking, message: "Cannot reach \(what) at \(client.base.absoluteString): \(message)")
    }
}

// MARK: - HTTP

/// The few requests discovery and probing make, with one place that attaches the credential.
/// Both header spellings are sent: a LiteLLM proxy reads `Authorization`, and Anthropic-shaped
/// local servers accept either.
struct HTTPClient {
    enum Outcome {
        case success(Int, Data)
        case failure(String)
    }

    let base: URL
    let token: String?
    let timeout: TimeInterval

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }

    func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    func get(_ path: String) async -> Outcome {
        await send(request(path))
    }

    func post(_ path: String, json: [String: Any]) async -> Outcome {
        var request = request(path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        return await send(request)
    }

    func send(_ request: URLRequest) async -> Outcome {
        do {
            let (data, response) = try await session.data(for: request)
            return .success((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            return .failure(Self.describe(error))
        }
    }

    /// Certificate failures get a message that says what to do. A private gateway usually has
    /// its own CA, and both ClaudeSwitch and Claude Code read the macOS trust store.
    static func describe(_ error: Error) -> String {
        let trustCodes: Set<Int> = [
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
            NSURLErrorSecureConnectionFailed,
        ]
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain, trustCodes.contains(nsError.code) else {
            return error.localizedDescription
        }
        return "the server's TLS certificate is not trusted on this Mac. Add the CA that signed it "
            + "to your login keychain — `security add-trusted-cert -r trustRoot -p ssl -k "
            + "~/Library/Keychains/login.keychain-db <ca.crt>` — after checking its fingerprint "
            + "with the server's administrator. Claude Code and Claude Desktop use the same trust store."
    }
}
