import Foundation
import Testing
@testable import ClaudeSwitchCore

/// The streaming half of the Anthropic dialect, which is the only half Claude Code uses.
///
/// These bodies are trimmed copies of what a LiteLLM gateway actually returned on 2026-09-11:
/// the non-streamed turn was perfect, and the streamed one opened a content block it never
/// closed — so Claude Code discarded the text and every reply arrived blank.
@Suite("Streaming SSE contract")
struct GatewayProbeTests {
    private func blank() -> GatewayProbe.Result {
        GatewayProbe.Result(reachable: true, publishedModels: [], messagesRouteOK: true,
                            streamingRouteOK: false, latency: nil, findings: [])
    }

    private static let wellFormed = """
    event: message_start
    data: {"type":"message_start"}

    event: content_block_start
    data: {"type":"content_block_start","index":0}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"text":"ok"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta"}

    event: message_stop
    data: {"type":"message_stop"}

    """

    @Test("Passes a stream that closes every block it opens")
    func acceptsWellFormed() {
        var result = blank()
        let findings = GatewayProbe.checkSSE(Self.wellFormed, into: &result)
        #expect(result.streamingRouteOK)
        #expect(result.isHealthy)
        #expect(findings.isEmpty)
    }

    @Test("Blocks the unclosed content block that renders as a blank reply")
    func rejectsMissingContentBlockStop() {
        let broken = Self.wellFormed.replacingOccurrences(of: """
        event: content_block_stop
        data: {"type":"content_block_stop","index":0}


        """, with: "")

        var result = blank()
        let findings = GatewayProbe.checkSSE(broken, into: &result)
        #expect(!result.streamingRouteOK)
        // Not healthy even though reachable and the non-streamed route answered — the whole
        // point of the third check.
        #expect(!result.isHealthy)
        #expect(findings.contains { $0.severity == .blocking })
        #expect(findings.contains { $0.message.contains("content_block_stop") })
    }

    @Test("Blocks a body that is not an SSE stream at all")
    func rejectsNonSSEBody() {
        var result = blank()
        let findings = GatewayProbe.checkSSE(#"{"type":"message","content":[]}"#, into: &result)
        #expect(!result.streamingRouteOK)
        #expect(findings.contains { $0.severity == .blocking })
    }

    @Test("Blocks a stream that never terminates the message")
    func rejectsMissingMessageStop() {
        let truncated = Self.wellFormed.replacingOccurrences(of: """
        event: message_stop
        data: {"type":"message_stop"}

        """, with: "")

        var result = blank()
        let findings = GatewayProbe.checkSSE(truncated, into: &result)
        #expect(!result.streamingRouteOK)
        #expect(findings.contains { $0.message.contains("message_stop") })
    }

    /// A thinking model given a small budget streams a perfectly terminated message with no
    /// text. Refusing that is what turned a healthy LM Studio away, so the route passes and the
    /// budget gets a caution.
    @Test("Passes, with a caution, a well-formed stream that carries no text")
    func cautionsOnEmptyStream() {
        let empty = Self.wellFormed.replacingOccurrences(of: """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"text":"ok"}}


        """, with: "")

        var result = blank()
        let findings = GatewayProbe.checkSSE(empty, into: &result)
        #expect(result.streamingRouteOK)
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.severity == .caution })
    }

    @Test("A thinking-only stream from LM Studio passes")
    func acceptsBlocklessStream() {
        // Captured from LM Studio serving qwen36-mlx8 with max_tokens 64: no content blocks at all.
        let body = """
        event: message_start
        data: {"type":"message_start"}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        var result = blank()
        _ = GatewayProbe.checkSSE(body, into: &result)
        #expect(result.streamingRouteOK)
    }

    @Test("A blocking finding makes a probe unhealthy even when the routes answer")
    func blockingFindingIsUnhealthy() {
        var result = blank()
        result.streamingRouteOK = true
        #expect(result.isHealthy)
        result.findings.append(Warning(severity: .blocking, message: "Model 'x' is not served here."))
        #expect(!result.isHealthy)
    }

    @Test("Summarises a reply's text, tool calls and stop reason")
    func summarisesMessages() {
        let tool = #"{"content":[{"type":"text","text":"Let me check."},{"type":"tool_use","id":"t","name":"get_time","input":{}}],"stop_reason":"tool_use"}"#
        let thinkingOnly = #"{"content":[],"stop_reason":"max_tokens"}"#
        #expect(GatewayProbe.summarizeMessage(Data(tool.utf8))
                == .init(textCharacters: 13, toolUses: 1, stopReason: "tool_use"))
        #expect(GatewayProbe.summarizeMessage(Data(thinkingOnly.utf8))
                == .init(textCharacters: 0, toolUses: 0, stopReason: "max_tokens"))
    }
}
