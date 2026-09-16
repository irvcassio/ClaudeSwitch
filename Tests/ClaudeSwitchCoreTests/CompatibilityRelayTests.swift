import Foundation
import Testing
@testable import ClaudeSwitchCore

@Suite("Compatibility relay")
struct CompatibilityRelayTests {
    private func fold(_ json: String) throws -> [[String: Any]]? {
        guard let data = CompatibilityRelay.foldSystemMessages(in: Data(json.utf8)) else { return nil }
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return root["messages"] as? [[String: Any]]
    }

    private func texts(_ message: [String: Any]) -> [String] {
        (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }

    @Test("Leaves a body with no system messages untouched")
    func passthrough() throws {
        #expect(try fold(#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#) == nil)
        #expect(try fold("not json") == nil)
    }

    @Test("Folds the shape Claude Code 2.1.200 sends into the user turn before it")
    func foldsAfterUser() throws {
        let messages = try #require(try fold(#"""
        {"model":"qwen38-claude","max_tokens":16384,"stream":true,"system":"top-level stays",
         "messages":[{"role":"user","content":"Reply with exactly: ok"},{"role":"system","content":"The date is 2026-09-16."}]}
        """#))
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(texts(messages[0]) == ["Reply with exactly: ok",
                                        "<system-reminder>\nThe date is 2026-09-16.\n</system-reminder>"])
        #expect(!messages.contains { $0["role"] as? String == "system" })
    }

    @Test("A system message after an assistant turn joins the next user turn")
    func foldsBeforeUser() throws {
        let messages = try #require(try fold(#"""
        {"messages":[
          {"role":"user","content":[{"type":"text","text":"q1"}]},
          {"role":"assistant","content":[{"type":"text","text":"a1"}]},
          {"role":"system","content":[{"type":"text","text":"ctx"}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"r"}]}
        ]}
        """#))
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let last = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(last.first?["text"] as? String == "<system-reminder>\nctx\n</system-reminder>")
        // Tool results keep their place and their fields.
        #expect(last.last?["type"] as? String == "tool_result")
        #expect(last.last?["tool_use_id"] as? String == "t")
    }

    @Test("A trailing system message after an assistant turn becomes a user turn")
    func trailingSystem() throws {
        let messages = try #require(try fold(#"""
        {"messages":[{"role":"user","content":"q"},{"role":"assistant","content":"a"},{"role":"system","content":"late"}]}
        """#))
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(texts(messages[2]) == ["<system-reminder>\nlate\n</system-reminder>"])
    }

    @Test("Keeps other request fields exactly")
    func keepsFields() throws {
        let data = try #require(CompatibilityRelay.foldSystemMessages(in: Data(#"""
        {"model":"m","max_tokens":16384,"stream":true,"temperature":1,"thinking":{"type":"enabled","budget_tokens":1024},
         "tools":[{"name":"t","input_schema":{"type":"object"}}],
         "messages":[{"role":"user","content":"x"},{"role":"system","content":"y"}]}
        """#.utf8)))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["stream"] as? Bool == true)
        #expect(root["max_tokens"] as? Int == 16384)
        #expect((root["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 1024)
        #expect((root["tools"] as? [Any])?.count == 1)
        // A JSON true must stay a boolean, not become 1.
        #expect(String(decoding: data, as: UTF8.self).contains("\"stream\":true"))
    }

    // MARK: - Parsing

    @Test("Parses a request once its body has fully arrived")
    func parsesContentLength() {
        let head = "POST /v1/messages?beta=true HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 11\r\nx-api-key: k\r\n\r\n"
        guard case .incomplete = HTTPRequest.parse(Data((head + "hello").utf8)) else {
            Issue.record("a partial body must wait")
            return
        }
        guard case .complete(let request) = HTTPRequest.parse(Data((head + "hello world").utf8)) else {
            Issue.record("a full body must parse")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/v1/messages")
        #expect(request.target == "/v1/messages?beta=true")
        #expect(String(decoding: request.body, as: UTF8.self) == "hello world")
        #expect(request.headers.contains { $0.0 == "x-api-key" && $0.1 == "k" })
    }

    @Test("Decodes a chunked request body")
    func parsesChunked() {
        let raw = "POST /v1/messages HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(String(decoding: request.body, as: UTF8.self) == "hello world")
        let partial = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel"
        guard case .incomplete = HTTPRequest.parse(Data(partial.utf8)) else {
            Issue.record("a partial chunk must wait")
            return
        }
    }

    // MARK: - End to end, offline

    /// The relay in front of a second relay-free listener would need a fake server; instead this
    /// checks the one thing that must hold with nothing upstream: the client gets an Anthropic-
    /// shaped error it can show, not a hung socket.
    @Test("An unreachable upstream yields a readable 502")
    func unreachableUpstream() async throws {
        let relay = CompatibilityRelay(port: UInt16.random(in: 49_200...49_900),
                                       upstream: URL(string: "http://127.0.0.1:9")!)
        try relay.startAndWait()
        defer { relay.stop() }
        var request = URLRequest(url: URL(string: relay.clientURL + "/v1/models")!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
        #expect(String(decoding: data, as: UTF8.self).contains("ClaudeSwitch relay"))
    }

    @Test("Listens on loopback only")
    func loopbackOnly() throws {
        let relay = CompatibilityRelay(port: UInt16.random(in: 49_200...49_900),
                                       upstream: URL(string: "http://127.0.0.1:9")!)
        try relay.startAndWait()
        defer { relay.stop() }
        #expect(relay.clientURL.hasPrefix("http://127.0.0.1:"))
        #expect(relay.state == .running)
    }
}
