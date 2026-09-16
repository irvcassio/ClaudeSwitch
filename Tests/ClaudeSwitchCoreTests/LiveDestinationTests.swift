import Foundation
import Testing
@testable import ClaudeSwitchCore

/// Runs discovery and the full probe against real servers. Skipped unless asked for:
///
///     CLAUDESWITCH_LIVE=1 swift test --filter Live
///
/// LM Studio is tried at its standard address. A LiteLLM proxy is tried only when
/// CLAUDESWITCH_LIVE_LITELLM_URL is set; its key is read from CLAUDESWITCH_LIVE_LITELLM_KEY and
/// the model from CLAUDESWITCH_LIVE_LITELLM_MODEL. Nothing here names anyone's network.
@Suite("Live destinations", .enabled(if: ProcessInfo.processInfo.environment["CLAUDESWITCH_LIVE"] == "1"))
struct LiveDestinationTests {
    private static let env = ProcessInfo.processInfo.environment

    private func report(_ result: GatewayProbe.Result) {
        for step in result.steps { print("  [\(step.state)] \(step.name): \(step.detail)") }
        for finding in result.findings { print("  - \(finding.severity): \(finding.message)") }
    }

    @Test("LM Studio: discover the loaded model, adopt its limits, and pass every check")
    func lmStudio() async throws {
        let base = Provider.lmStudio.defaultBaseURL
        let listing = await DestinationDiscovery.discover(provider: .lmStudio, baseURL: base, token: "lmstudio")
        let model = try #require(listing.selectableModels.first, "no loaded model in LM Studio")
        let length = try #require(model.contextLength)
        print("LM Studio: \(model.id) at \(length)")

        var profile = Profile.blank(name: "Live LM Studio", provider: .lmStudio)
        profile.model = model.id
        profile.haikuModel = model.id
        profile.sonnetModel = model.id
        profile.opusModel = model.id
        profile.adopt(LimitPlan.plan(modelLength: length))
        #expect(profile.isUsable, "\(profile.staticWarnings.map(\.message))")

        let result = await GatewayProbe.run(profile: profile, authToken: nil)
        report(result)
        #expect(result.isHealthy)
        #expect(result.serverLength == length)
        #expect(result.toolUseOK == true)
        #expect(await GatewayProbe.liveness(profile: profile, authToken: nil) == .up)
    }

    @Test("LiteLLM: measure the real ceiling, and catch a window that would hang",
          .enabled(if: env["CLAUDESWITCH_LIVE_LITELLM_URL"] != nil))
    func liteLLM() async throws {
        let base = try #require(Self.env["CLAUDESWITCH_LIVE_LITELLM_URL"])
        let key = Self.env["CLAUDESWITCH_LIVE_LITELLM_KEY"]
        let listing = await DestinationDiscovery.discover(provider: .liteLLM, baseURL: base, token: key)
        print("LiteLLM models: \(listing.models.map { "\($0.id)\($0.isSelectable ? "" : " (not selectable)")" })")
        #expect(!listing.models.contains { $0.id == "triage-agent" && $0.isSelectable })

        let modelID = try #require(Self.env["CLAUDESWITCH_LIVE_LITELLM_MODEL"] ?? listing.selectableModels.first?.id)
        let measured = try #require(await DestinationDiscovery.serverLength(provider: .liteLLM, baseURL: base, token: key, model: modelID))
        print("LiteLLM: \(modelID) measured at \(measured)")

        var profile = Profile.blank(name: "Live LiteLLM", provider: .liteLLM)
        profile.baseURL = base
        profile.model = modelID
        profile.haikuModel = modelID
        profile.sonnetModel = modelID
        profile.opusModel = modelID

        // The configuration that hangs: the window set to the server's full length.
        profile.contextWindow = measured
        profile.maxOutputTokens = 16_384
        let bad = await GatewayProbe.run(profile: profile, authToken: key)
        report(bad)
        #expect(!bad.isHealthy)
        #expect(bad.steps.first { $0.name == "Limits" }?.state == .failed)

        profile.adopt(LimitPlan.plan(modelLength: measured))
        let good = await GatewayProbe.run(profile: profile, authToken: key)
        report(good)
        #expect(good.isHealthy)
        #expect(good.serverLength == measured)
        #expect(await GatewayProbe.liveness(profile: profile, authToken: key) == .up)
    }

    // MARK: - The CLI, end to end

    /// Writes the profile through the same store a switch uses, into a throwaway config dir, and
    /// asks the real `claude` binary for a reply. Proves the keys ClaudeSwitch writes are the keys
    /// Claude Code reads.
    private func cliReply(profile: Profile, token: String) throws -> (reply: String, models: [String]) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cs-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ClaudeSettingsStore(url: dir.appending(path: "settings.json")).apply(profile: profile, authToken: token)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["claude", "-p", "Reply with exactly the word: pong", "--output-format", "json"]
        process.currentDirectoryURL = dir
        // A clean environment, as a fresh terminal would have — nothing inherited from a host app.
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "CLAUDE_CONFIG_DIR": dir.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"),
              let json = try JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any]
        else { return (text, []) }
        let models = (json["modelUsage"] as? [String: Any]).map { Array($0.keys) } ?? []
        return ((json["result"] as? String) ?? text, models)
    }

    @Test("CLI: a switched settings file sends turns to LM Studio")
    func cliThroughLMStudio() async throws {
        let listing = await DestinationDiscovery.discover(provider: .lmStudio,
                                                          baseURL: Provider.lmStudio.defaultBaseURL, token: "lmstudio")
        let model = try #require(listing.selectableModels.first)
        var profile = Profile.blank(name: "Live LM Studio", provider: .lmStudio)
        for keyPath in [\Profile.model, \.haikuModel, \.sonnetModel, \.opusModel] { profile[keyPath: keyPath] = model.id }
        profile.adopt(LimitPlan.plan(modelLength: try #require(model.contextLength)))

        let (reply, models) = try cliReply(profile: profile, token: try #require(profile.effectiveToken(savedKey: nil)))
        print("CLI via LM Studio: \(reply.debugDescription) models=\(models)")
        #expect(reply.localizedCaseInsensitiveContains("pong"))
        #expect(models == [model.id])
    }

    @Test("CLI: a switched settings file sends turns to the LiteLLM proxy",
          .enabled(if: env["CLAUDESWITCH_LIVE_LITELLM_URL"] != nil))
    func cliThroughLiteLLM() async throws {
        let base = try #require(Self.env["CLAUDESWITCH_LIVE_LITELLM_URL"])
        let key = try #require(Self.env["CLAUDESWITCH_LIVE_LITELLM_KEY"])
        let modelID = try #require(Self.env["CLAUDESWITCH_LIVE_LITELLM_MODEL"])
        var profile = Profile.blank(name: "Live LiteLLM", provider: .liteLLM)
        profile.baseURL = base
        for keyPath in [\Profile.model, \.haikuModel, \.sonnetModel, \.opusModel] { profile[keyPath: keyPath] = modelID }
        let measured = try #require(await DestinationDiscovery.serverLength(provider: .liteLLM, baseURL: base, token: key, model: modelID))
        profile.adopt(LimitPlan.plan(modelLength: measured))

        let (reply, models) = try cliReply(profile: profile, token: key)
        print("CLI via LiteLLM: \(reply.debugDescription) models=\(models)")
        // Until the proxy folds mid-conversation system messages itself, a direct session fails
        // with exactly this rejection — the one the probe's request-shape check reports. Once the
        // server is fixed the reply comes back instead; either outcome is a correct reading.
        if reply.contains("Input should be 'user' or 'assistant'") {
            let probe = await GatewayProbe.run(profile: profile, authToken: key)
            #expect(probe.midConversationSystemOK == false, "the CLI failed on the shape but the probe did not catch it")
        } else {
            #expect(reply.localizedCaseInsensitiveContains("pong"))
            #expect(models == [modelID])
        }
    }

    // MARK: - Through the relay

    private func liteLLMProfile(relayPort: Int) async throws -> (Profile, String) {
        let base = try #require(Self.env["CLAUDESWITCH_LIVE_LITELLM_URL"])
        let key = try #require(Self.env["CLAUDESWITCH_LIVE_LITELLM_KEY"])
        let modelID = try #require(Self.env["CLAUDESWITCH_LIVE_LITELLM_MODEL"])
        var profile = Profile.blank(name: "Live LiteLLM via relay", provider: .liteLLM)
        profile.baseURL = base
        profile.relayPort = relayPort
        for keyPath in [\Profile.model, \.haikuModel, \.sonnetModel, \.opusModel] { profile[keyPath: keyPath] = modelID }
        let measured = try #require(await DestinationDiscovery.serverLength(provider: .liteLLM, baseURL: base, token: key, model: modelID))
        profile.adopt(LimitPlan.plan(modelLength: measured))
        return (profile, key)
    }

    @Test("Relay: the proxy passes every check through the relay, fixed server or not",
          .enabled(if: env["CLAUDESWITCH_LIVE_LITELLM_URL"] != nil))
    func relayProbe() async throws {
        let port = Int.random(in: 48_000...48_900)
        let (profile, key) = try await liteLLMProfile(relayPort: port)
        let relay = CompatibilityRelay(port: UInt16(port), upstream: try #require(URL(string: profile.baseURL)))
        try relay.startAndWait()
        defer { relay.stop() }

        var direct = profile
        direct.relayPort = 0
        let without = await GatewayProbe.run(profile: direct, authToken: key)
        print("direct:"); report(without)
        // A proxy with aiserver's compatibility hook takes the shape directly; one without it
        // does not, and must then be unhealthy. The relay has to work either way.
        if without.midConversationSystemOK == false {
            #expect(!without.isHealthy)
        } else {
            #expect(without.isHealthy)
        }

        let with = await GatewayProbe.run(profile: profile, authToken: key)
        print("relayed:"); report(with)
        #expect(with.midConversationSystemOK == true)
        #expect(with.isHealthy)
        #expect(relay.foldedRequests >= 1)
    }

    @Test("Relay: the CLI works against the proxy through the relay",
          .enabled(if: env["CLAUDESWITCH_LIVE_LITELLM_URL"] != nil))
    func relayCLI() async throws {
        let port = Int.random(in: 48_000...48_900)
        let (profile, key) = try await liteLLMProfile(relayPort: port)
        let relay = CompatibilityRelay(port: UInt16(port), upstream: try #require(URL(string: profile.baseURL)))
        try relay.startAndWait()
        defer { relay.stop() }

        let (reply, models) = try cliReply(profile: profile, token: key)
        print("CLI via relay: \(reply.debugDescription) models=\(models) folded=\(relay.foldedRequests)")
        #expect(reply.localizedCaseInsensitiveContains("pong"))
        #expect(models == [profile.model])
    }

    // MARK: - Over TLS

    /// A LiteLLM proxy behind HTTPS with a private CA, relying on the macOS trust store alone —
    /// no certificate file is handed to anything. Run once before trusting the CA (it must fail
    /// with the trust message) and once after (it must pass end to end).
    @Test("TLS: the proxy over HTTPS, trusted through the macOS keychain only",
          .enabled(if: env["CLAUDESWITCH_LIVE_LITELLM_TLS_URL"] != nil))
    func liteLLMOverTLS() async throws {
        let base = try #require(Self.env["CLAUDESWITCH_LIVE_LITELLM_TLS_URL"])
        let key = try #require(Self.env["CLAUDESWITCH_LIVE_LITELLM_KEY"])
        let modelID = try #require(Self.env["CLAUDESWITCH_LIVE_LITELLM_MODEL"])
        var profile = Profile.blank(name: "Live LiteLLM over TLS", provider: .liteLLM)
        profile.baseURL = base
        for keyPath in [\Profile.model, \.haikuModel, \.sonnetModel, \.opusModel] { profile[keyPath: keyPath] = modelID }
        // HTTPS on the network is what the desktop accepts without a relay.
        profile.switchesDesktop = true
        #expect(DesktopGatewayStore.ineligibility(of: profile) == nil)

        let listing = await DestinationDiscovery.discover(provider: .liteLLM, baseURL: base, token: key)
        if let failure = listing.findings.first(where: { $0.message.contains("not trusted on this Mac") }) {
            print("TLS: CA not trusted yet — \(failure.message)")
            Issue.record("The CA is not trusted on this Mac yet.")
            return
        }
        let length = try #require(await DestinationDiscovery.serverLength(provider: .liteLLM, baseURL: base, token: key, model: modelID, listing: listing))
        profile.adopt(LimitPlan.plan(modelLength: length))
        let result = await GatewayProbe.run(profile: profile, authToken: key)
        report(result)
        #expect(result.isHealthy)

        let (reply, models) = try cliReply(profile: profile, token: key)
        print("CLI via TLS (keychain trust only): \(reply.debugDescription) models=\(models)")
        #expect(reply.localizedCaseInsensitiveContains("pong"))
    }
}
