import Foundation
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

    @Test("Blocks base URLs that cannot be right", arguments: [
        "http://gateway.example:4000/v1",
        "http://gateway.example:4000/v1/",
        "gateway.example:4000",
        "ftp://gateway.example",
        "",
    ])
    func blocksBadBaseURLs(url: String) {
        var profile = Self.fixture()
        profile.baseURL = url
        #expect(!profile.isUsable)
    }

    @Test("Warns about effort levels Qwen3.8 rejects", arguments: ["high", "max"])
    func warnsOnBadEffort(level: String) {
        var profile = Self.fixture()
        profile.model = "qwen38-claude"
        profile.effortLevel = level
        #expect(profile.staticWarnings.contains { $0.message.contains("500") })
    }

    @Test("Does not warn about effort for models that are not Qwen3.8")
    func effortWarningIsModelSpecific() {
        var profile = Self.fixture()
        profile.effortLevel = "high"
        #expect(!profile.staticWarnings.contains { $0.message.contains("500") })
    }

    @Test("Warns when an id will be hidden by the model picker")
    func warnsOnPickerFilter() {
        var profile = Self.fixture()
        profile.enableGatewayModelDiscovery = true
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
        // Without this the compact window is capped at Claude Code's 200K default for a
        // non-Claude model id.
        #expect(env.first { $0.key == "CLAUDE_CODE_MAX_CONTEXT_TOKENS" }?.value == "131072")
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

    // MARK: - Providers

    @Test("Local providers start on their standard address and need no key")
    func localProvidersAreKeyless() {
        for provider in [Provider.lmStudio, .ollama] {
            let blank = Profile.blank(provider: provider)
            #expect(blank.baseURL == provider.defaultBaseURL)
            #expect(!provider.requiresKey)
            // Never empty: an empty token makes Claude Code send the subscription credential instead.
            #expect(blank.effectiveToken(savedKey: nil) == provider.placeholderToken)
            #expect(blank.effectiveToken(savedKey: "") == provider.placeholderToken)
        }
        #expect(Profile.blank(provider: .liteLLM).baseURL.isEmpty)
        #expect(Profile.blank(provider: .liteLLM).effectiveToken(savedKey: nil) == nil)
        #expect(Profile.blank(provider: .liteLLM).effectiveToken(savedKey: "sk-x") == "sk-x")
    }

    @Test("Ollama's own port is fine for an Ollama destination")
    func ollamaPortAllowed() {
        var profile = Self.fixture()
        profile.provider = .ollama
        profile.baseURL = "http://127.0.0.1:11434"
        #expect(profile.isUsable)
    }

    @Test("A proxy profile on a local server's port suggests the right provider")
    func suggestsProviderForKnownPorts() {
        var profile = Self.fixture()
        profile.baseURL = "http://127.0.0.1:1234"
        #expect(profile.staticWarnings.contains { $0.message.contains("LM Studio") && $0.severity == .caution })
    }

    // MARK: - Limits

    @Test("Blocks a window that overflows the server once a session gets long")
    func blocksOverflowingWindow() {
        var profile = Self.fixture()
        profile.modelLength = 262_144
        profile.contextWindow = 262_144   // what the old help text told people to enter
        profile.maxOutputTokens = 16_384
        #expect(!profile.isUsable)
        #expect(profile.staticWarnings.contains { $0.message.contains("HTTP 500") })
    }

    @Test("Adopting a plan produces a usable profile")
    func adoptingPlanFits() {
        var profile = Self.fixture()
        profile.adopt(LimitPlan.plan(modelLength: 262_144))
        #expect(profile.isUsable)
        #expect(profile.contextWindow + profile.maxOutputTokens < 262_144)
    }

    @Test("Blocks a missing output ceiling")
    func blocksMissingOutputCeiling() {
        var profile = Self.fixture()
        profile.maxOutputTokens = 0
        #expect(!profile.isUsable)
    }

    // MARK: - Desktop

    @Test("The desktop takes HTTPS or loopback only", arguments: [
        ("https://gateway.example", true),
        ("http://127.0.0.1:1234", true),
        ("http://localhost:11434", true),
        ("http://10.80.0.1:4000", false),
        ("http://gateway.example:4000", false),
    ])
    func desktopEligibility(url: String, eligible: Bool) {
        var profile = Self.fixture()
        profile.baseURL = url
        #expect((DesktopGatewayStore.ineligibility(of: profile) == nil) == eligible)
        profile.switchesDesktop = true
        #expect(profile.isUsable == eligible)
    }

    // MARK: - Persistence

    @Test("Profiles saved before providers existed still load, as LiteLLM proxies")
    func decodesLegacyProfiles() throws {
        let legacy = """
        [{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"Old","baseURL":"http://gateway.example:4000",
          "model":"m","haikuModel":"m","sonnetModel":"m","opusModel":"m","effortLevel":"medium",
          "contextWindow":131072,"maxOutputTokens":16384,"disableNonessentialTraffic":true,
          "enableGatewayModelDiscovery":false}]
        """
        let profiles = try JSONDecoder().decode([Profile].self, from: Data(legacy.utf8))
        #expect(profiles.count == 1)
        #expect(profiles[0].provider == .liteLLM)
        #expect(profiles[0].modelLength == 0)
        #expect(!profiles[0].switchesDesktop)

        let roundTrip = try JSONDecoder().decode([Profile].self, from: JSONEncoder().encode(profiles))
        #expect(roundTrip == profiles)
    }
}
