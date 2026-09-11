import AppKit
import Foundation
import Sparkle
import os

/// Which appcast items this install is willing to receive.
///
/// Sparkle 2 semantics: an app that opts into the `beta` channel receives both
/// channel-tagged *and* untagged items; an app on stable receives only untagged
/// items. So "stable" is an **empty** allowed-set, not a `"stable"` tag — the
/// appcast carries one `<sparkle:channel>beta</sparkle:channel>` on beta items
/// and nothing at all on stable ones.
public enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case beta

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stable: return "Stable"
        case .beta: return "Beta"
        }
    }

    public var summary: String {
        switch self {
        case .stable: return "Only tested releases. Recommended."
        case .beta: return "Pre-release builds as soon as they ship, plus stable releases."
        }
    }

    /// The value handed to `SPUUpdaterDelegate.allowedChannelsForUpdater:`.
    public var allowedChannels: Set<String> {
        switch self {
        case .stable: return []
        case .beta: return ["beta"]
        }
    }

    public static let defaultsKey = "updateChannel"

    public static var current: UpdateChannel {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let channel = UpdateChannel(rawValue: raw) else {
            return .stable
        }
        return channel
    }
}

/// What the user should be told about the updater right now.
public enum UpdateStatus: Equatable {
    /// No Info.plist feed — a `swift build` / test binary, not a packaged app.
    case unsupported
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case failed(String)
    /// Downloaded and staged, but deliberately not installed — it applies when
    /// the app quits. `deferredBecause` is non-nil when a relaunch was actively
    /// postponed rather than merely waiting for a quit.
    case readyToInstall(version: String, deferredBecause: String?)
}

/// Owns Sparkle for the app.
///
/// Two things carried over from Doppo Terminal's updater, because both are
/// load-bearing rather than stylistic:
///
/// * The Beta/Stable picker maps to `allowedChannelsForUpdater:`, so one build
///   serves both channels and switching takes effect on the next check (which
///   the setter triggers immediately).
/// * The app never relaunches itself over work in flight. ClaudeSwitch's work is
///   short — a gateway switch rewrites `settings.json` and may relaunch the
///   Claude desktop app — but a relaunch landing mid-write is exactly how you
///   end up with a half-written settings file. So: install-on-quit is the
///   default timing, an explicit "Install and Relaunch" is postponed while a
///   switch is running, and every deferral is visible instead of silent.
///
/// Sparkle invokes its delegate on the main thread; the delegate methods below
/// are `nonisolated` (they satisfy `@objc` protocol requirements) and hop back
/// onto the main actor with `MainActor.assumeIsolated`.
public final class UpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate {
    public static let shared = UpdaterService()

    private static let log = Logger(subsystem: "com.irvcassio.ClaudeSwitch", category: "update")

    @MainActor @Published public private(set) var status: UpdateStatus = .unsupported
    @MainActor @Published public private(set) var canCheckForUpdates = false

    @MainActor @Published public var channel: UpdateChannel = .current {
        didSet {
            guard oldValue != channel else { return }
            UserDefaults.standard.set(channel.rawValue, forKey: UpdateChannel.defaultsKey)
            // Re-check immediately so switching to Beta doesn't wait for the
            // next scheduled cycle to surface a build the user just opted into.
            updater?.checkForUpdatesInBackground()
        }
    }

    /// Returns nil when the app is idle, or a human-readable reason why an
    /// install-and-relaunch must wait. Injected by the app so this service stays
    /// free of settings-file internals.
    @MainActor public var busyReasonProvider: (() -> String?)?

    @MainActor public private(set) var controller: SPUStandardUpdaterController?
    @MainActor private var updater: SPUUpdater? { controller?.updater }

    /// Set when Sparkle asks to relaunch while we're busy. Invoked once the app
    /// goes idle — the user already asked to install, so completing it at the
    /// first safe moment is what they asked for.
    @MainActor private var postponedRelaunchHandler: (() -> Void)?
    /// Set when Sparkle has staged an update for install-on-quit. Invoking it
    /// installs immediately and relaunches — only ever from the user-driven
    /// "Install and Relaunch Now" button, and only when idle.
    @MainActor private var immediateInstallHandler: (() -> Void)?
    @MainActor private var idleWatchdog: Timer?
    @MainActor private var canCheckObservation: NSKeyValueObservation?
    @MainActor private var stagedVersion: String?

    private override init() { super.init() }

    // MARK: - Lifecycle

    /// True only in a packaged `.app` that carries the Sparkle feed keys. A bare
    /// `swift build` binary (or the test host) has no Info.plist feed, and
    /// starting Sparkle there aborts with a configuration error.
    @MainActor
    public var isSupported: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        return !feed.isEmpty
    }

    @MainActor
    public func start() {
        guard controller == nil else { return }
        guard isSupported else {
            status = .unsupported
            Self.log.debug("No SUFeedURL in Info.plist — updater disabled for this build.")
            return
        }

        // The busy gate depends on two block-taking delegate methods whose Swift
        // labels must match their Objective-C selectors EXACTLY. A near-miss
        // compiles with only a "nearly matches optional requirement" warning and
        // is then never called, silently disabling the gate. The `@objc(...)`
        // attributes below pin the selectors; this asserts the binding at
        // runtime as a second layer.
        for selector in [
            "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
            "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
        ] {
            if !responds(to: NSSelectorFromString(selector)) {
                Self.log.error("Delegate is NOT bound to \(selector) — the busy gate is inactive.")
                assertionFailure("Sparkle delegate selector unbound: \(selector)")
            }
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller
        status = .idle

        let updater = controller.updater
        // Automatic background checks are declared in Info.plist
        // (SUEnableAutomaticChecks); downloading in the background is what makes
        // install-on-quit possible, so default it on for the first launch only —
        // after that the user's own choice wins.
        if UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") == nil {
            updater.automaticallyDownloadsUpdates = true
        }

        canCheckForUpdates = updater.canCheckForUpdates
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    // MARK: - User-facing actions

    @MainActor
    public func checkForUpdates() {
        guard let controller else { return }
        status = .checking
        controller.checkForUpdates(nil)
    }

    /// The "Install and Relaunch Now" button. Refuses while busy.
    @MainActor
    public func installNow() {
        guard let handler = immediateInstallHandler else { return }
        if let reason = busyReasonProvider?() {
            status = .readyToInstall(version: stagedVersion ?? "", deferredBecause: reason)
            return
        }
        immediateInstallHandler = nil
        handler()
    }

    /// Human-readable "why not now" for the UI, or nil when installing is safe.
    @MainActor
    public var busyReason: String? { busyReasonProvider?() }

    // MARK: - Idle watchdog

    /// Poll for the app going idle so a *postponed relaunch* can complete on its
    /// own. Only armed for the postponed-relaunch path (the user already clicked
    /// "Install and Relaunch"); the install-on-quit path never auto-fires — it
    /// waits for a real quit or an explicit button press.
    @MainActor
    private func armIdleWatchdog() {
        guard idleWatchdog == nil else { return }
        idleWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickIdleWatchdog() }
        }
    }

    @MainActor
    private func tickIdleWatchdog() {
        guard let handler = postponedRelaunchHandler else {
            idleWatchdog?.invalidate()
            idleWatchdog = nil
            return
        }
        if let reason = busyReasonProvider?() {
            status = .readyToInstall(version: stagedVersion ?? "", deferredBecause: reason)
            return
        }
        idleWatchdog?.invalidate()
        idleWatchdog = nil
        postponedRelaunchHandler = nil
        Self.log.debug("App went idle — completing postponed relaunch.")
        handler()
    }

    // MARK: - SPUUpdaterDelegate

    /// The in-app channel selector.
    public nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.current.allowedChannels
    }

    /// The busy gate on relaunch. Returning `true` holds the relaunch until
    /// `installHandler` runs, which we only do once nothing is in flight; until
    /// then the deferral is visible in Settings ▸ Updates and in the menu.
    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    public nonisolated func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            stagedVersion = item.displayVersionString
            guard let reason = busyReasonProvider?() else {
                return false   // idle — let Sparkle relaunch right now
            }
            Self.log.debug("Postponing relaunch: \(reason)")
            postponedRelaunchHandler = installHandler
            status = .readyToInstall(version: item.displayVersionString, deferredBecause: reason)
            armIdleWatchdog()
            return true
        }
    }

    /// Prefer install-on-quit. Returning `true` takes ownership: Sparkle stages
    /// the update, installs it when the app terminates, and never interrupts the
    /// running app on its own. We keep `immediateInstallHandler` so the user can
    /// choose to install early when nothing is in flight.
    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    public nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            self.immediateInstallHandler = immediateInstallHandler
            stagedVersion = item.displayVersionString
            status = .readyToInstall(
                version: item.displayVersionString,
                deferredBecause: busyReasonProvider?()
            )
            Self.log.debug("Update \(item.displayVersionString) staged for install on quit.")
            return true
        }
    }

    public nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { stagedVersion = item.displayVersionString }
    }

    public nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        MainActor.assumeIsolated {
            if case .readyToInstall = status { return }
            status = .upToDate(checkedAt: Date())
        }
    }

    public nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if case .readyToInstall = status { return }
            guard let error = error as NSError? else {
                status = .upToDate(checkedAt: Date())
                return
            }
            switch error.code {
            case Int(SUError.noUpdateError.rawValue):
                status = .upToDate(checkedAt: Date())
            case Int(SUError.installationCanceledError.rawValue):
                status = .idle   // the user backed out; not a failure
            default:
                status = .failed(error.localizedDescription)
            }
        }
    }
}
