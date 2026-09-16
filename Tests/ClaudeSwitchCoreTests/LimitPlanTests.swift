import Testing
@testable import ClaudeSwitchCore

/// The arithmetic that keeps a long session from wedging: prompt + output must stay under the
/// server's ceiling, or a LiteLLM proxy answers 500 and Claude Code retries forever.
@Suite("Limit planning")
struct LimitPlanTests {
    @Test("The window leaves room for the output ceiling and a margin", arguments: [8_192, 32_768, 131_072, 262_144])
    func windowPlusOutputFits(length: Int) {
        let plan = LimitPlan.plan(modelLength: length)
        #expect(plan.compactWindow + plan.maxOutputTokens < length)
        #expect(plan.compactWindow + plan.maxOutputTokens + LimitPlan.margin(for: length) <= length)
        #expect(LimitPlan.problem(modelLength: length, compactWindow: plan.compactWindow,
                                  maxOutputTokens: plan.maxOutputTokens) == nil)
    }

    @Test("Qwen3.8 behind LiteLLM: 262,144 tokens")
    func measuredRemoteQwen() {
        // max_model_len=262144, measured on 2026-09-16.
        let plan = LimitPlan.plan(modelLength: 262_144)
        #expect(plan.maxOutputTokens == 16_384)
        #expect(plan.compactWindow == 262_144 - 16_384 - 5_242)
    }

    @Test("Honours an output limit the server reports")
    func clampsToServerOutput() {
        #expect(LimitPlan.plan(modelLength: 262_144, desiredMaxOutput: 32_000, serverMaxOutput: 8_192)
            .maxOutputTokens == 8_192)
    }

    @Test("Never plans more than a quarter of a small model for output")
    func smallModelsKeepAWindow() {
        let plan = LimitPlan.plan(modelLength: 16_384, desiredMaxOutput: 16_384)
        #expect(plan.maxOutputTokens == 4_096)
        #expect(plan.compactWindow > 0)
    }

    @Test("Setting the window to the server length is the hang, and is reported")
    func fullLengthWindowIsAProblem() {
        let message = LimitPlan.problem(modelLength: 262_144, compactWindow: 262_144, maxOutputTokens: 16_384)
        #expect(message != nil)
        #expect(message?.contains("HTTP 500") == true)
    }

    @Test("Unknown length is not a problem — there is nothing to check against")
    func unknownLengthIsUnchecked() {
        #expect(LimitPlan.problem(modelLength: 0, compactWindow: 999_999, maxOutputTokens: 999_999) == nil)
    }
}
