import Foundation
import Testing
@testable import ClaudeSwitchCore

/// The codec is the riskiest part of the app: it rewrites a file the user hand-maintains.
/// These tests exist to prove a toggle never costs anyone their settings.
@Suite("JSON round-trip")
struct JSONValueTests {
    @Test("Preserves top-level key order")
    func keyOrder() throws {
        let text = #"{"z": 1, "a": 2, "m": 3}"#
        let keys = try JSONValue.parse(text).objectEntries?.map(\.key)
        #expect(keys == ["z", "a", "m"])

        let reserialized = try JSONValue.parse(try JSONValue.parse(text).serialized())
        #expect(reserialized.objectEntries?.map(\.key) == ["z", "a", "m"])
    }

    @Test("Keeps integers as integers")
    func integerFidelity() throws {
        // 131072 becoming 131072.0 would be a valid JSON number and an invalid env value.
        let out = try JSONValue.parse(#"{"n": 131072}"#).serialized()
        #expect(out.contains("131072"))
        #expect(!out.contains("131072.0"))
    }

    @Test("Survives escapes, unicode and surrogate pairs")
    func escapes() throws {
        let text = #"{"s": "q\" b\\ t\t n\n é 🚀 🎯"}"#
        let value = try JSONValue.parse(text)
        let original = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
        let round = try JSONSerialization.jsonObject(with: Data(value.serialized().utf8)) as? NSDictionary
        #expect(original == round)
        #expect(value["s"]?.stringValue?.contains("🚀") == true)
    }

    @Test("Preserves empty containers and nesting")
    func containers() throws {
        let text = #"{"o": {}, "a": [], "deep": {"x": [{"y": null}, true, false]}}"#
        let out = try JSONValue.parse(text).serialized()
        let original = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
        let round = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? NSDictionary
        #expect(original == round)
        #expect(out.contains("{}"))
        #expect(out.contains("[]"))
    }

    @Test("Rejects malformed input rather than guessing")
    func malformed() {
        #expect(throws: (any Error).self) { try JSONValue.parse(#"{"broken": "#) }
        #expect(throws: (any Error).self) { try JSONValue.parse("{,}") }
        #expect(throws: (any Error).self) { try JSONValue.parse(#"{"a": 1} trailing"#) }
    }

    @Test("Round-trips the live settings file byte-for-byte, if one exists")
    func liveSettingsFile() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let out = try JSONValue.parse(text).serialized() + "\n"
        let original = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
        let round = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? NSDictionary
        #expect(original == round)
    }
}
