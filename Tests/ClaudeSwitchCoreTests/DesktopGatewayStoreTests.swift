import Foundation
import Testing
@testable import ClaudeSwitchCore

/// Every test works in a throwaway copy of the desktop's `Claude-3p` folder; none touch the real one.
@Suite("Desktop gateway store")
struct DesktopGatewayStoreTests {
    static func lmStudio() -> Profile {
        var p = Profile.blank(name: "Local Qwen", provider: .lmStudio)
        p.model = "qwen36-mlx8"
        p.haikuModel = "qwen36-mlx8"
        p.sonnetModel = "qwen36-mlx8"
        p.opusModel = "qwen36-mlx8"
        p.switchesDesktop = true
        return p
    }

    private func makeStore() throws -> DesktopGatewayStore {
        let root = FileManager.default.temporaryDirectory.appending(path: "cs3p-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return DesktopGatewayStore(root: root)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    @Test("Activating writes an applied gateway entry and opens the desktop on it")
    func activate() throws {
        let store = try makeStore()
        try store.activate(profile: Self.lmStudio(), token: "lmstudio")

        let state = store.state()
        #expect(state.isOnGateway)
        #expect(state.baseURL == "http://127.0.0.1:1234")
        #expect(state.models == ["qwen36-mlx8"])
        #expect(state.hasKey)

        let id = try #require(state.entryID)
        // The desktop only accepts lowercase ids.
        #expect(id == id.lowercased())
        let entry = try json(store.entryURL(id))
        #expect(entry["inferenceProvider"] as? String == "gateway")
        #expect(entry["modelDiscoveryEnabled"] as? String == "false")
        // Every value is a string, as the desktop's configuration encoding requires.
        #expect(entry.values.allSatisfy { $0 is String })

        let perms = try FileManager.default.attributesOfItem(atPath: store.entryURL(id).path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test("Distinct aliases become distinct models with their tiers")
    func modelsCarryTiers() throws {
        var profile = Self.lmStudio()
        profile.haikuModel = "small-model"
        let entry = DesktopGatewayStore.entry(for: profile, token: "x")
        let text = try #require(entry["inferenceModels"]?.stringValue)
        let models = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        #expect(models.map { $0["name"] as? String } == ["qwen36-mlx8", "small-model"])
        #expect(models.map { $0["anthropicFamilyTier"] as? String } == ["sonnet", "haiku"])
    }

    @Test("Deactivating returns to Claude.ai, takes the key off disk, and restores the user's own config")
    func deactivateRestores() throws {
        let store = try makeStore()
        // The user already had a configuration of their own applied, and other app settings.
        try FileManager.default.createDirectory(at: store.libraryURL, withIntermediateDirectories: true)
        let theirs = "11111111-2222-3333-4444-555555555555"
        try #"{"appliedId":"\#(theirs)","entries":[{"id":"\#(theirs)","name":"Work"}]}"#
            .write(to: store.metaURL, atomically: true, encoding: .utf8)
        try #"{"inferenceProvider":"bedrock"}"#.write(to: store.entryURL(theirs), atomically: true, encoding: .utf8)
        try #"{"isDxtAutoUpdatesEnabled":true}"#.write(to: store.appConfigURL, atomically: true, encoding: .utf8)

        try store.activate(profile: Self.lmStudio(), token: "secret-token")
        #expect(store.state().isOnGateway)
        #expect(try json(store.metaURL)["entries"] as? [Any] != nil)
        #expect((try json(store.metaURL)["entries"] as? [Any])?.count == 2)

        try store.deactivate()
        let state = store.state()
        #expect(state.mode == .claudeAI)
        #expect(!state.isOnGateway)
        #expect(!state.hasKey)
        #expect(try json(store.metaURL)["appliedId"] as? String == theirs)
        // Their entry and the app's other settings are untouched.
        #expect(try json(store.entryURL(theirs))["inferenceProvider"] as? String == "bedrock")
        #expect(try json(store.appConfigURL)["isDxtAutoUpdatesEnabled"] as? Bool == true)
    }

    @Test("Re-activating reuses ClaudeSwitch's one entry")
    func reusesEntry() throws {
        let store = try makeStore()
        try store.activate(profile: Self.lmStudio(), token: "a")
        let first = store.state().entryID
        try store.activate(profile: Self.lmStudio(), token: "b")
        #expect(store.state().entryID == first)
        #expect((try json(store.metaURL)["entries"] as? [Any])?.count == 1)
    }

    @Test("Refuses a plain-HTTP network gateway, which the desktop would reject")
    func refusesNetworkHTTP() throws {
        let store = try makeStore()
        var profile = Self.lmStudio()
        profile.provider = .liteLLM
        profile.baseURL = "http://10.0.0.1:4000"
        #expect(throws: DesktopGatewayStore.StoreError.self) {
            try store.activate(profile: profile, token: "sk-x")
        }
        #expect(store.state().mode == nil)
    }

    @Test("Deactivating when the desktop was never configured writes nothing")
    func deactivateNoop() throws {
        let store = try makeStore()
        try store.deactivate()
        #expect(!FileManager.default.fileExists(atPath: store.appConfigURL.path))
    }
}
