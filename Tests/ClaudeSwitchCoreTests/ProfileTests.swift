import Testing
@testable import ClaudeSwitchCore

/// Each of these corresponds to a trap you hit when pointing Claude Code at a self-hosted
/// gateway. Catching them in the UI is the whole point — every one of them otherwise costs
/// an afternoon.
@Suite("Profile validation")
struct ProfileTests {
    /// A stand-in gateway. Deliberately a documentation host: nothing in this repo should carry
    /// a real address.
    static func fixture() -> Profile {
        var p = Profile.blank(name: "Example gateway")
        p.baseURL = "http://gateway.example:4000"
        p.model = "claude-proxy"
        p.haikuModel = "claude-proxy"
        p.sonnetModel = "claude-proxy"
        p.opusModel = "claude-proxy"
        return p
    }

    @Test("A new gateway starts empty — no address, no model, not switchable")
    func blankCarriesNoDestination() {
        let blank = Profile.blank()
        #expect(blank.baseURL.isEmpty)
        #expect(blank.model.isEmpty)
        #expect(blank.haikuModel.isEmpty)
        // Unusable on purpose: there is nowhere to switch to until the user fills it in.
        #expect(!blank.isUsable)
    }

    @Test("A filled-in gateway is valid")
    func fixtureIsUsable() {
        #expect(Self.fixture().isUsable)
        #expect(Self.fixture().staticWarnings.allSatisfy { $0.severity != .blocking })
    }

    @Test("Blocks base URLs that cannot serve /v1/messages", arguments: [
        "http://gateway.example:8001",
        "http://gateway.example:11434",
        "http://gateway.example:4000/v1",
        "http://gateway.example:4000/v1/",
    ])
    func blocksBadBaseURLs(url: String) {
        var profile = Self.fixture()
        profile.baseURL = url
        #expect(!profile.isUsable)
    }

    @Test("Warns about effort levels Qwen3.8 rejects", arguments: ["high", "max"])
    func warnsOnBadEffort(level: String) {
        var profile = Self.fixture()
        profile.effortLevel = level
        #expect(profile.staticWarnings.contains { $0.message.contains("500") })
    }

    @Test("Warns when an id will be hidden by the model picker")
    func warnsOnPickerFilter() {
        var profile = Self.fixture()
        profile.model = "plain-qwen"
        #expect(profile.staticWarnings.contains { $0.message.contains("/model will hide it") })
    }

    @Test("Warns that plain HTTP puts the key on the wire in the clear")
    func warnsOnPlainHTTP() {
        #expect(Self.fixture().staticWarnings.contains { $0.message.contains("clear") })
    }

    @Test("Writes every variable a gateway needs")
    func environmentCoversRequiredKeys() {
        let env = Self.fixture().environment(authToken: "sk-x")
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
        var maximal = Self.fixture()
        maximal.enableGatewayModelDiscovery = true
        for pair in maximal.environment(authToken: "sk-x") {
            #expect(ClaudeSettingsStore.managedKeys.contains(pair.key),
                    "\(pair.key) is written but not declared managed, so it would never be cleaned up")
        }
    }
}
