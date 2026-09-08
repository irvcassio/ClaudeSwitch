import Testing
@testable import ClaudeSwitchCore

/// Each of these corresponds to a trap in the aiserver developer guide. Catching them in the
/// UI is the whole point — every one of them otherwise costs an afternoon.
@Suite("Profile validation")
struct ProfileTests {
    @Test("The aiserver default is valid")
    func defaultIsUsable() {
        #expect(Profile.aiserver().isUsable)
        #expect(Profile.aiserver().staticWarnings.allSatisfy { $0.severity != .blocking })
    }

    @Test("The aiserver default uses the id the gateway actually publishes")
    func defaultUsesPublishedID() {
        // Verified against the live gateway: qwen38-claude was never added, and a scoped key
        // answers 403 for it. The prefixed id is the one that returns 200 on /v1/messages.
        let profile = Profile.aiserver()
        #expect(profile.model == "Qwen/Qwen3.8-27B-FP8")
        #expect(profile.haikuModel == profile.model)
        // The prefix matters: the unprefixed form is a different team's server.
        #expect(profile.model.hasPrefix("Qwen/"))
    }

    @Test("Blocks vLLM's port — it has no /v1/messages route", arguments: [
        "http://10.80.114.11:8001",
        "http://10.80.114.11:11434",
        "http://10.80.114.11:4000/v1",
        "http://10.80.114.11:4000/v1/",
    ])
    func blocksBadBaseURLs(url: String) {
        var profile = Profile.aiserver()
        profile.baseURL = url
        #expect(!profile.isUsable)
    }

    @Test("Warns about the unprefixed id, which is another team's server")
    func warnsOnUnprefixedModelID() {
        var profile = Profile.aiserver()
        profile.model = "Qwen3.8-27B-FP8"
        #expect(profile.staticWarnings.contains { $0.message.contains("different team") })
        // A caution, not a blocker: it is a real id, just the wrong one.
        #expect(profile.isUsable)
    }

    @Test("Warns about effort levels Qwen3.8 rejects", arguments: ["high", "max"])
    func warnsOnBadEffort(level: String) {
        var profile = Profile.aiserver()
        profile.effortLevel = level
        #expect(profile.staticWarnings.contains { $0.message.contains("500") })
    }

    @Test("Warns when an id will be hidden by the model picker")
    func warnsOnPickerFilter() {
        var profile = Profile.aiserver()
        profile.model = "plain-qwen"
        #expect(profile.staticWarnings.contains { $0.message.contains("/model will hide it") })
    }

    @Test("Warns that plain HTTP puts the key on the wire in the clear")
    func warnsOnPlainHTTP() {
        #expect(Profile.aiserver().staticWarnings.contains { $0.message.contains("clear") })
    }

    @Test("Writes every variable the guide marks required")
    func environmentCoversRequiredKeys() {
        let env = Profile.aiserver().environment(authToken: "sk-x")
        let keys = Set(env.map(\.key))
        for required in ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL",
                         "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_EFFORT_LEVEL",
                         "CLAUDE_CODE_AUTO_COMPACT_WINDOW"] {
            #expect(keys.contains(required), "missing \(required)")
        }
        #expect(env.first { $0.key == "CLAUDE_CODE_AUTO_COMPACT_WINDOW" }?.value == "131072")
        // ANTHROPIC_API_KEY would go in X-Api-Key and is for real Anthropic keys only.
        #expect(!keys.contains("ANTHROPIC_API_KEY"))
    }

    @Test("Every key it writes is one it declares it owns")
    func writesOnlyManagedKeys() {
        var maximal = Profile.aiserver()
        maximal.enableGatewayModelDiscovery = true
        for pair in maximal.environment(authToken: "sk-x") {
            #expect(ClaudeSettingsStore.managedKeys.contains(pair.key),
                    "\(pair.key) is written but not declared managed, so it would never be cleaned up")
        }
    }
}
