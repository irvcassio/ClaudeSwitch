import AppKit
import Foundation

/// Things outside `settings.json` that can quietly contradict it.
public enum Diagnostics {
    public struct ShellOverride: Identifiable, Hashable {
        public var id: String { "\(file):\(line)" }
        public let file: String
        public let line: Int
        public let variable: String
    }

    private static let shellFiles = [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile"]
    private static let watchedPrefixes = ["ANTHROPIC_", "CLAUDE_CODE_"]

    /// Uncommented `ANTHROPIC_*` / `CLAUDE_CODE_*` exports in the login shell's dotfiles.
    ///
    /// This matters in both directions. While a profile is active, `settings.json` wins and the
    /// export is dead weight. But the moment we switch back to Anthropic and remove the managed
    /// keys, any surviving export becomes live again — so the CLI would stay pointed at the
    /// gateway while the menu says Anthropic. Worth showing rather than guessing about.
    public static func shellOverrides() -> [ShellOverride] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out: [ShellOverride] = []

        for name in shellFiles {
            let url = home.appending(path: name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#") else { continue }
                for prefix in watchedPrefixes {
                    guard let range = line.range(of: prefix) else { continue }
                    // Only an assignment counts; a mention inside a comment or string does not.
                    let rest = line[range.lowerBound...]
                    guard let equals = rest.firstIndex(of: "="),
                          rest[rest.startIndex ..< equals].allSatisfy({
                              $0.isLetter || $0.isNumber || $0 == "_"
                          })
                    else { continue }
                    out.append(ShellOverride(file: name, line: index + 1,
                                             variable: String(rest[rest.startIndex ..< equals])))
                }
            }
        }
        return out
    }

    /// Running `claude` processes. They read settings at launch, so a switch does not reach them.
    public static func runningCLISessionCount() -> Int {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-f", "(^|/)claude( |$)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }
}

/// Quits and reopens the Claude desktop app, which reads `settings.json` only at launch.
public enum ClaudeDesktopApp {
    public static let bundleID = "com.anthropic.claudefordesktop"

    public static var isRunning: Bool { !runningInstances.isEmpty }

    private static var runningInstances: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    /// Asks the app to quit, waits for it to actually go, then relaunches. A forced kill would
    /// lose unsaved work in an open session, so this stays polite and reports if it was refused.
    public static func relaunch() async throws {
        for app in runningInstances { app.terminate() }

        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while ContinuousClock().now < deadline, !runningInstances.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard runningInstances.isEmpty else { throw RelaunchError.didNotQuit }

        try await launch()
    }

    public static func launch() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw RelaunchError.notInstalled
        }
        try await NSWorkspace.shared.openApplication(at: url,
                                                     configuration: NSWorkspace.OpenConfiguration())
    }

    public enum RelaunchError: LocalizedError {
        case notInstalled, didNotQuit
        public var errorDescription: String? {
            switch self {
            case .notInstalled: "The Claude desktop app is not installed."
            case .didNotQuit:
                "Claude did not quit — it may be showing a confirmation dialog. Quit it by hand, "
                + "then reopen it to pick up the new settings."
            }
        }
    }
}
