import ClaudeSwitchCore
import SwiftUI

/// Settings ▸ Updates — the channel picker and the honest status of any staged
/// update, including *why* it hasn't been installed yet.
public struct UpdatesSettingsView: View {
    @EnvironmentObject private var updater: UpdaterService

    public init() {}

    public var body: some View {
        Form {
            Section("Update Channel") {
                Picker("Channel", selection: Binding(
                    get: { updater.channel },
                    set: { updater.channel = $0 }
                )) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!updater.isSupported)

                Text(updater.channel.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Status") {
                statusRow

                HStack {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    Spacer()
                    Text("Version \(AppVersion.marketing) (build \(AppVersion.build))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if case .readyToInstall(let version, let reason) = updater.status {
                Section("Staged Update") {
                    stagedUpdateRows(version: version, reason: reason)
                }
            }

            Section("How updates are applied") {
                Text("""
                Updates download in the background and install when you quit \
                ClaudeSwitch, so a relaunch never lands in the middle of \
                rewriting settings.json. Switching gateway is unaffected either \
                way — Claude Code reads the file at launch, not from this app.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Updates")
    }

    @ViewBuilder
    private var statusRow: some View {
        switch updater.status {
        case .unsupported:
            Label("Automatic updates aren't available in this build.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .idle:
            Label("Automatic checks are on.", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        case .upToDate(let at):
            Label("Up to date — checked \(at.formatted(date: .abbreviated, time: .shortened)).",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .readyToInstall(let version, _):
            Label("Version \(version) is downloaded and ready.", systemImage: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func stagedUpdateRows(version: String, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Version \(version) will be installed the next time you quit ClaudeSwitch.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = reason ?? updater.busyReason {
                Label("Deferred: \(reason). Installing now would interrupt it.",
                      systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Install and Relaunch Now") { updater.installNow() }
                .disabled(updater.busyReason != nil)

            if updater.busyReason != nil {
                Text("Let the switch finish to enable this.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The menu-bar entries.
///
/// ClaudeSwitch is an `LSUIElement` app with no app menu, so the menu-bar popover
/// is the only always-reachable surface — the channel lives here *as well as* in
/// Settings ▸ Updates, which is not a duplicate to be tidied away. Both read and
/// write the same `UpdaterService.channel`, so neither can report a channel the
/// other is not on.
public struct UpdateMenuItems: View {
    @EnvironmentObject private var updater: UpdaterService

    public init() {}

    public var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)

        if case .readyToInstall(let version, _) = updater.status {
            Button("Update to \(version) on Quit") {}
                .disabled(true)
        }

        Menu("Update Channel") {
            // A Picker inside a menu renders as one checkmarked row per case.
            // The checkmark is the only thing that reports which channel is live.
            Picker("Update Channel", selection: Binding(
                get: { updater.channel },
                set: { updater.channel = $0 }
            )) {
                ForEach(UpdateChannel.allCases) { channel in
                    Text(channel.displayName).tag(channel)
                }
            }
            .pickerStyle(.inline)
        }
        .disabled(!updater.isSupported)
    }
}
