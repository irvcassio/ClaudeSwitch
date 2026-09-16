import Foundation
import Testing
@testable import ClaudeSwitchCore

@Suite("Settings store")
struct ClaudeSettingsStoreTests {
    /// A stand-in gateway on a documentation host. Fully filled in, so it writes every key it
    /// can — the counts below depend on that.
    static func fixture() -> Profile {
        var p = Profile.blank(name: "Example gateway")
        p.baseURL = "http://gateway.example:4000"
        p.model = "claude-proxy"
        p.haikuModel = "claude-proxy"
        p.sonnetModel = "claude-proxy"
        p.opusModel = "claude-proxy"
        return p
    }

    /// Each test gets a throwaway settings file; none of them touch the real one.
    private func makeStore(_ contents: String? = nil) throws -> ClaudeSettingsStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "settings.json")
        if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
        return ClaudeSettingsStore(url: url)
    }

    @Test("Apply then clear restores the file byte-for-byte, in canonical format")
    func applyClearIsLossless() throws {
        // Two-space indent with expanded arrays — what Claude Code itself writes, and what
        // this store emits. A file already in this shape survives a toggle untouched.
        let original = """
        {
          "permissions": {
            "allow": [
              "Bash(*)"
            ]
          },
          "model": "claude-opus-4-7",
          "theme": "light"
        }

        """
        let store = try makeStore(original)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        #expect(try store.readManagedEnvironment().count == 11)

        try store.clearManagedEnvironment()
        #expect(try String(contentsOf: store.url, encoding: .utf8) == original)
    }

    @Test("Apply then clear is lossless in meaning even for compact input")
    func applyClearPreservesMeaning() throws {
        // A hand-written file with inline arrays gets normalised to the canonical format on the
        // first write. That is a reformat, not a change: every key, value and order survives.
        let original = #"{"permissions": {"allow": ["Bash(*)"]}, "theme": "light"}"#
        let store = try makeStore(original)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        try store.clearManagedEnvironment()

        let before = try JSONSerialization.jsonObject(with: Data(original.utf8)) as? NSDictionary
        let after = try JSONSerialization.jsonObject(
            with: Data(try String(contentsOf: store.url, encoding: .utf8).utf8)) as? NSDictionary
        #expect(before == after)
        #expect(try JSONValue.parse(try String(contentsOf: store.url, encoding: .utf8))
            .objectEntries?.map(\.key) == ["permissions", "theme"])
    }

    @Test("Leaves the user's own env keys alone")
    func preservesUnmanagedKeys() throws {
        let store = try makeStore(#"{"env": {"MY_OWN": "keep-me"}}"#)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        #expect(try store.readUnmanagedEnvironment()["MY_OWN"] == "keep-me")

        try store.clearManagedEnvironment()
        #expect(try store.readUnmanagedEnvironment()["MY_OWN"] == "keep-me")
        #expect(try store.readManagedEnvironment().isEmpty)
    }

    @Test("Replaces a stale value instead of leaving both")
    func replacesStaleValues() throws {
        let store = try makeStore(#"{"env": {"ANTHROPIC_BASE_URL": "http://stale:1"}}"#)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        #expect(try store.readManagedEnvironment()["ANTHROPIC_BASE_URL"] == "http://gateway.example:4000")
    }

    @Test("Drops optional keys a profile turns off")
    func dropsOptionalKeys() throws {
        let store = try makeStore()
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        #expect(try store.readManagedEnvironment()["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] != nil)

        var lean = Self.fixture()
        lean.maxOutputTokens = 0
        lean.disableNonessentialTraffic = false
        try store.apply(profile: lean, authToken: "sk-test")

        let env = try store.readManagedEnvironment()
        #expect(env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == nil)
        #expect(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == nil)
        #expect(env["ANTHROPIC_BASE_URL"] != nil)
    }

    @Test("Removes an env block it emptied, rather than leaving env: {}")
    func removesEmptiedEnvBlock() throws {
        let store = try makeStore(#"{"theme": "light"}"#)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        try store.clearManagedEnvironment()
        let root = try JSONValue.parse(try String(contentsOf: store.url, encoding: .utf8))
        #expect(root["env"] == nil)
        #expect(root["theme"]?.stringValue == "light")
    }

    @Test("Creates a missing file rather than failing")
    func createsMissingFile() throws {
        let store = try makeStore()
        #expect(try store.readManagedEnvironment().isEmpty)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        #expect(FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test("Refuses malformed JSON and leaves the file untouched")
    func refusesMalformed() throws {
        let store = try makeStore(#"{ "broken": "#)
        let before = try String(contentsOf: store.url, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try store.apply(profile: Self.fixture(), authToken: "sk-test")
        }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == before)
    }

    @Test("Refuses a non-object top level")
    func refusesNonObjectRoot() throws {
        let store = try makeStore("[1, 2, 3]")
        #expect(throws: (any Error).self) {
            try store.apply(profile: Self.fixture(), authToken: "sk-test")
        }
    }

    @Test("Backs the file up once, and never overwrites the backup")
    func backsUpOnce() throws {
        let store = try makeStore(#"{"theme": "original"}"#)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        let backup = try String(contentsOf: store.backupURL, encoding: .utf8)
        #expect(backup.contains("original"))

        try store.apply(profile: Self.fixture(), authToken: "sk-test-2")
        #expect(try String(contentsOf: store.backupURL, encoding: .utf8) == backup)
    }

    // MARK: - Top-level overrides
    //
    // A top-level `model` outranks ANTHROPIC_MODEL, and `effortLevel` outranks
    // CLAUDE_CODE_EFFORT_LEVEL. Leaving them in place is the failure this app exists to prevent:
    // the switch reports success, and every turn still goes to the old destination.

    @Test("Sets aside the top-level keys that outrank the env block")
    func stripsOverridingTopLevelKeys() throws {
        let store = try makeStore(#"{"model": "claude-opus-5", "effortLevel": "high", "theme": "light"}"#)
        #expect(try store.readTopLevelOverrides().count == 2)

        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        #expect(try store.readTopLevelOverrides().isEmpty)
        #expect(try store.readManagedEnvironment()["ANTHROPIC_MODEL"] == "claude-proxy")
        #expect(try store.readManagedEnvironment()["CLAUDE_CODE_EFFORT_LEVEL"] == "medium")
    }

    @Test("Puts each override back in the position it was found")
    func restoresOverridesInPlace() throws {
        let original = """
        {
          "model": "claude-opus-5",
          "permissions": {
            "allow": [
              "Bash(*)"
            ]
          },
          "effortLevel": "high",
          "theme": "light"
        }

        """
        let store = try makeStore(original)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        try store.clearManagedEnvironment()
        #expect(try String(contentsOf: store.url, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: store.overridesStashURL.path))
    }

    @Test("A second switch does not lose the originals")
    func stashSurvivesRepeatedApply() throws {
        let store = try makeStore(#"{"model": "claude-opus-5", "theme": "light"}"#)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        // Updating the live profile applies again, and by then the key is already gone — the
        // stash must not be overwritten with the empty set.
        try store.apply(profile: Self.fixture(), authToken: "sk-test-2")

        try store.clearManagedEnvironment()
        let root = try JSONValue.parse(try String(contentsOf: store.url, encoding: .utf8))
        #expect(root["model"]?.stringValue == "claude-opus-5")
    }

    @Test("Restores a non-string override as the value it was")
    func restoresNonStringOverride() throws {
        let store = try makeStore(#"{"effortLevel": null, "theme": "light"}"#)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        try store.clearManagedEnvironment()
        let root = try JSONValue.parse(try String(contentsOf: store.url, encoding: .utf8))
        #expect(root["effortLevel"]?.serialized() == "null")
    }

    @Test("Picks up a key the user re-added while a gateway was active")
    func stashesLateAdditions() throws {
        let store = try makeStore(#"{"model": "claude-opus-5", "theme": "light"}"#)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")

        // The user hand-edits effortLevel back in, then switches gateways.
        var text = try String(contentsOf: store.url, encoding: .utf8)
        text = text.replacingOccurrences(of: "{\n", with: "{\n  \"effortLevel\": \"high\",\n")
        try text.write(to: store.url, atomically: true, encoding: .utf8)
        try store.apply(profile: Self.fixture(), authToken: "sk-test")
        #expect(try store.readTopLevelOverrides().isEmpty)

        try store.clearManagedEnvironment()
        let root = try JSONValue.parse(try String(contentsOf: store.url, encoding: .utf8))
        #expect(root["model"]?.stringValue == "claude-opus-5")
        #expect(root["effortLevel"]?.stringValue == "high")
    }

    @Test("Clearing a file it never managed changes nothing")
    func clearIsNoOpWhenUnmanaged() throws {
        let store = try makeStore("{\n  \"theme\": \"light\"\n}\n")
        let before = try String(contentsOf: store.url, encoding: .utf8)
        try store.clearManagedEnvironment()
        #expect(try String(contentsOf: store.url, encoding: .utf8) == before)
    }
}
