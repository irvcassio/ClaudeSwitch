import Foundation
import Testing
@testable import ClaudeSwitchCore

/// Each fixture is a trimmed copy of what the real server returned on 2026-09-16.
@Suite("Destination discovery parsing")
struct DiscoveryParsingTests {
    static let lmStudio = """
    {"data":[
      {"id":"qwen36-mlx8","type":"vlm","state":"loaded","max_context_length":262144,"loaded_context_length":262144,"arch":"qwen3_5_moe","quantization":"8bit"},
      {"id":"qwen3.6-35b-a3b","type":"vlm","state":"not-loaded","max_context_length":262144,"arch":"qwen3_5_moe","quantization":"8bit"},
      {"id":"text-embedding-nomic-embed-text-v1.5","type":"embeddings","state":"not-loaded","max_context_length":2048}
    ],"object":"list"}
    """

    @Test("LM Studio: only the loaded instance is selectable, at its loaded length")
    func lmStudioLoadedInstance() {
        let models = DestinationDiscovery.parseLMStudio(Data(Self.lmStudio.utf8))
        #expect(models.count == 3)
        let selectable = models.filter(\.isSelectable)
        #expect(selectable.map(\.id) == ["qwen36-mlx8"])
        #expect(selectable.first?.contextLength == 262_144)

        // Same weights, not loaded: picking it would load a second 38 GB copy.
        let unloaded = models.first { $0.id == "qwen3.6-35b-a3b" }
        #expect(unloaded?.isLoaded == false)
        #expect(unloaded?.isSelectable == false)
        #expect(unloaded?.contextLength == nil)

        #expect(models.first { $0.id.contains("embed") }?.isChatModel == false)
        // Selectable models sort first, so the picker opens on something usable.
        #expect(models.first?.id == "qwen36-mlx8")
    }

    @Test("LM Studio: a model loaded at less than its maximum reports the loaded length")
    func lmStudioReducedContext() {
        let json = #"{"data":[{"id":"m","type":"llm","state":"loaded","max_context_length":262144,"loaded_context_length":131072}]}"#
        #expect(DestinationDiscovery.parseLMStudio(Data(json.utf8)).first?.contextLength == 131_072)
    }

    static let liteLLMInfo = """
    {"data":[
      {"model_name":"qwen38-claude","litellm_params":{"model":"openai/Qwen/Qwen3.8-27B-FP8"},"model_info":{"max_tokens":null,"max_input_tokens":262144,"max_output_tokens":null}},
      {"model_name":"qwen3-embedding","litellm_params":{"model":"openai/qwen3-embedding"},"model_info":{"max_input_tokens":8192,"mode":"embedding"}},
      {"model_name":"triage-agent","litellm_params":{"model":"openai/triage-agent"},"model_info":{}}
    ]}
    """

    @Test("LiteLLM: reads the input limit and spots embeddings")
    func liteLLMInfo() {
        let info = DestinationDiscovery.parseLiteLLMInfo(Data(Self.liteLLMInfo.utf8))
        #expect(info["qwen38-claude"]?.maxInput == 262_144)
        #expect(info["qwen38-claude"]?.maxOutput == nil)
        #expect(info["qwen3-embedding"]?.isEmbedding == true)
        #expect(info["triage-agent"] != nil)
    }

    @Test("Reads the ceiling out of the refusals vLLM gives through LiteLLM")
    func lengthFromRefusal() {
        // max_tokens above the model length.
        let tooMuchOutput = #"{"error":{"message":"litellm.InternalServerError: InternalServerError: OpenAIException - {\"type\":\"error\",\"error\":{\"type\":\"internal_error\",\"message\":\"max_completion_tokens=300000 cannot be greater than max_model_len=max_total_tokens=262144. Please request fewer output tokens.\"}}","code":"500"}}"#
        // max_tokens equal to the model length, so prompt + output overflows.
        let overflow = #"{"error":{"message":"litellm.ContextWindowExceededError: ContextWindowExceededError: OpenAIException - {\"error\":{\"message\":\"This model's maximum context length is 262144 tokens. However, you requested 262161 tokens.\"}}"}}"#
        #expect(DestinationDiscovery.parseLengthFromError(tooMuchOutput) == 262_144)
        #expect(DestinationDiscovery.parseLengthFromError(overflow) == 262_144)
        #expect(DestinationDiscovery.parseLengthFromError(#"{"error":"bad key"}"#) == nil)
    }

    @Test("Ollama: served length comes from num_ctx, not the architecture maximum")
    func ollamaShow() {
        let json = """
        {"parameters":"temperature 0.6\\nnum_ctx 32768\\nstop \\"<|im_end|>\\"",
         "model_info":{"general.architecture":"qwen3","qwen3.context_length":262144},
         "capabilities":["completion","tools","thinking"]}
        """
        let show = DestinationDiscovery.parseOllamaShow(Data(json.utf8))
        #expect(show.numCtx == 32_768)
        #expect(show.architectureMaximum == 262_144)
        #expect(show.isChatModel)

        let embedding = #"{"model_info":{"bert.context_length":2048},"capabilities":["embedding"]}"#
        let embed = DestinationDiscovery.parseOllamaShow(Data(embedding.utf8))
        #expect(embed.numCtx == nil)
        #expect(!embed.isChatModel)
    }

    @Test("Ollama: loaded models and the length they were loaded at")
    func ollamaPS() {
        let json = #"{"models":[{"name":"qwen3:32b","model":"qwen3:32b","context_length":40960},{"name":"old:1b","model":"old:1b"}]}"#
        let loaded = DestinationDiscovery.parseOllamaPS(Data(json.utf8))
        #expect(loaded["qwen3:32b"] == .some(40_960))
        #expect(loaded["old:1b"] == .some(nil))
        #expect(loaded["absent"] == nil)
    }

    @Test("Never sends a request to the production triage tool")
    func triageIsNeverProbed() async {
        #expect(DestinationDiscovery.neverProbe.contains("triage-agent"))
        // Returns before any network call — the base URL here would not resolve.
        #expect(await DestinationDiscovery.measureLength(baseURL: "http://unresolvable.invalid",
                                                         token: "x", model: "triage-agent") == nil)
    }
}

@Suite("HTTP errors")
struct HTTPErrorTests {
    @Test("An untrusted certificate says how to fix it")
    func untrustedCertificate() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
        let message = HTTPClient.describe(error)
        #expect(message.contains("not trusted on this Mac"))
        #expect(message.contains("add-trusted-cert"))
    }

    @Test("Other errors keep their own description")
    func otherErrors() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        #expect(HTTPClient.describe(error) == error.localizedDescription)
    }

    /// What nginx on aiserver's :4443 answered on 2026-09-16 to `http://10.80.114.11:4443/v1/models`.
    static let plainHTTPToTLSPort = """
    <html>
    <head><title>400 The plain HTTP request was sent to HTTPS port</title></head>
    <body>
    <center><h1>400 Bad Request</h1></center>
    <center>The plain HTTP request was sent to HTTPS port</center>
    <hr><center>nginx</center>
    </body>
    </html>
    """

    @Test("A TLS port asked for in plain HTTP names the scheme, not the model id")
    func plainHTTPAgainstTLSPort() {
        let client = HTTPClient(base: URL(string: "http://10.80.114.11:4443")!, token: "k", timeout: 1)
        let warning = DestinationDiscovery.schemeMismatch(client, code: 400,
                                                          body: Data(Self.plainHTTPToTLSPort.utf8))
        #expect(warning?.severity == .blocking)
        #expect(warning?.message.contains("https://10.80.114.11:4443") == true)
        #expect(warning?.message.contains("model id is not the problem") == true)
    }

    @Test("An unrelated 400, or one already on https, keeps the generic advice")
    func otherBadRequests() {
        let plain = HTTPClient(base: URL(string: "http://10.80.114.11:4000")!, token: "k", timeout: 1)
        #expect(DestinationDiscovery.schemeMismatch(plain, code: 400,
                                                    body: Data(#"{"error":"bad model"}"#.utf8)) == nil)
        // Already https: whatever the 400 is, the scheme is not it.
        let secure = HTTPClient(base: URL(string: "https://10.80.114.11:4443")!, token: "k", timeout: 1)
        #expect(DestinationDiscovery.schemeMismatch(secure, code: 400,
                                                    body: Data(Self.plainHTTPToTLSPort.utf8)) == nil)
        // Only a 400 carries this body.
        #expect(DestinationDiscovery.schemeMismatch(plain, code: 502,
                                                    body: Data(Self.plainHTTPToTLSPort.utf8)) == nil)
    }
}
