import Foundation

/// Turns a server's real ceiling into the two numbers Claude Code needs.
///
/// A model server enforces one limit on the *sum* of the prompt and the requested output. vLLM
/// calls it `max_model_len`; LM Studio calls it the loaded context length. Claude Code asks for
/// `CLAUDE_CODE_MAX_OUTPUT_TOKENS` on every turn and only compacts once the conversation nears
/// its window — `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, with `CLAUDE_CODE_AUTO_COMPACT_WINDOW` inside it.
/// If the window is set to the full server length, a long
/// conversation eventually sends `prompt + max_tokens > max_model_len`. A LiteLLM proxy answers
/// that with HTTP 500 rather than 400, Claude Code retries 500s, and the session appears to hang.
///
/// So the window is never the server length. It is the server length minus the output ceiling,
/// minus a margin for the tokens a turn adds between compaction checks.
public struct LimitPlan: Equatable {
    /// The server's ceiling on prompt + output together.
    public let modelLength: Int
    public let maxOutputTokens: Int
    public let compactWindow: Int

    /// The smallest window worth running Claude Code in. Its system prompt and tool list alone
    /// are tens of thousands of tokens; below this, every turn compacts.
    public static let minimumUsefulWindow = 32_768

    /// A generous default output ceiling. Reasoning counts towards it, and a thinking model that
    /// spends the whole allowance thinking returns an empty reply — so it must not be small. It
    /// is also the only guard against a model spiralling in its thinking block.
    public static let defaultMaxOutputTokens = 16_384

    public static func margin(for modelLength: Int) -> Int {
        max(4_096, modelLength / 50)
    }

    /// Plans a window for `modelLength`. The output ceiling is clamped to whatever the server
    /// itself reports as its output limit, and to a quarter of the length, so a small model
    /// is not planned into a window too small to hold a session.
    public static func plan(modelLength: Int,
                            desiredMaxOutput: Int = defaultMaxOutputTokens,
                            serverMaxOutput: Int? = nil) -> LimitPlan {
        var output = max(1, desiredMaxOutput)
        if let serverMaxOutput, serverMaxOutput > 0 { output = min(output, serverMaxOutput) }
        output = min(output, max(1, modelLength / 4))
        let window = max(0, modelLength - output - margin(for: modelLength))
        return LimitPlan(modelLength: modelLength, maxOutputTokens: output, compactWindow: window)
    }

    /// Checks numbers the user typed against a known server length. Returns nil when they fit.
    public static func problem(modelLength: Int, compactWindow: Int, maxOutputTokens: Int) -> String? {
        guard modelLength > 0 else { return nil }
        let needed = compactWindow + maxOutputTokens
        if needed > modelLength {
            let safe = plan(modelLength: modelLength, desiredMaxOutput: maxOutputTokens)
            return "Context window \(compactWindow.formatted()) + max output "
                + "\(maxOutputTokens.formatted()) = \(needed.formatted()) tokens, but the server "
                + "stops at \(modelLength.formatted()). Once a conversation gets that long every "
                + "turn is rejected — a LiteLLM proxy answers HTTP 500, Claude Code keeps "
                + "retrying, and the session looks hung. Use a context window of "
                + "\(safe.compactWindow.formatted()) or less."
        }
        return nil
    }
}
