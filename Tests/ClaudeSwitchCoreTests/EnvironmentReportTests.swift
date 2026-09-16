import Testing
@testable import ClaudeSwitchCore

@Suite("Environment report")
struct EnvironmentReportTests {
    static func profile() -> Profile {
        var p = Profile.blank(name: "Remote Qwen", provider: .liteLLM)
        p.baseURL = "http://gateway.example:4000"
        p.model = "qwen38-claude"
        p.haikuModel = "qwen38-claude"
        p.sonnetModel = "qwen38-claude"
        p.opusModel = "qwen38-claude"
        return p
    }

    @Test("Never shows a key, and says which keys the desktop ignores")
    func masksSecrets() {
        let token = "sk-abcdefghijklmnopqrstu"
        let report = EnvironmentReport.build(
            profile: Self.profile(), token: token,
            managed: Self.profile().environment(authToken: token)
                .reduce(into: [:]) { $0[$1.key] = $1.value },
            unmanaged: [:], shell: [])
        let auth = report.rows.first { $0.key == "ANTHROPIC_AUTH_TOKEN" }
        #expect(auth?.status == .set)
        #expect(auth?.inSettings?.contains("abcdef") == false)
        #expect(auth?.inSettings == "sk-•••• (24 chars)")
        #expect(auth?.reach == .cliOnly)
        #expect(report.rows.first { $0.key == "ANTHROPIC_MODEL" }?.reach == .both)
    }

    @Test("Different keys of the same length are a mismatch, not a match")
    func comparesBeforeMasking() {
        let report = EnvironmentReport.build(
            profile: Self.profile(), token: "sk-aaaaaaaa",
            managed: ["ANTHROPIC_AUTH_TOKEN": "sk-bbbbbbbb"], unmanaged: [:], shell: [])
        #expect(report.rows.first { $0.key == "ANTHROPIC_AUTH_TOKEN" }?.status == .mismatch)
    }

    @Test("On Anthropic, a leftover managed key is a stray and a shell export is listed")
    func straysAndExports() {
        let report = EnvironmentReport.build(
            profile: nil, token: nil,
            managed: ["ANTHROPIC_MODEL": "qwen38-claude"], unmanaged: [:],
            shell: [Diagnostics.ShellOverride(file: ".zshenv", line: 3, variable: "ANTHROPIC_BASE_URL")])
        #expect(report.rows.first { $0.key == "ANTHROPIC_MODEL" }?.status == .stray)
        #expect(report.rows.first { $0.key == "ANTHROPIC_BASE_URL" }?.shellExports == ["~/.zshenv:3"])
        #expect(report.rows.first { $0.key == "CLAUDE_CODE_EFFORT_LEVEL" }?.status == .unset)
    }

    @Test("Related keys appear only when something sets them")
    func relatedKeysOnlyWhenSet() {
        let quiet = EnvironmentReport.build(profile: nil, token: nil, managed: [:], unmanaged: [:], shell: [])
        #expect(!quiet.rows.contains { $0.key == "ANTHROPIC_API_KEY" })
        let loud = EnvironmentReport.build(profile: nil, token: nil, managed: [:],
                                           unmanaged: ["ANTHROPIC_API_KEY": "sk-ant-zzzzzzzzzz"], shell: [])
        #expect(loud.rows.first { $0.key == "ANTHROPIC_API_KEY" }?.status == .stray)
    }

    @Test("Placeholders are shown as-is; they are not secrets")
    func placeholdersVisible() {
        #expect(EnvironmentReport.mask("lmstudio") == "lmstudio")
        #expect(EnvironmentReport.mask("") == "(empty)")
    }
}
