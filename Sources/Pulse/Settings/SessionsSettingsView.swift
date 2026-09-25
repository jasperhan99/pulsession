import SwiftUI

/// The session monitor's pane: what is read, how the rail behaves for it,
/// PI-Desktop's control port, and the sessions taken off the panel.
struct SessionsSettingsView: View {
    let monitor: SessionMonitor

    @State private var confirmsRelaunch = false
    @State private var isRelaunching = false
    @State private var relaunchFailed = false

    private var settings: SessionSettings { monitor.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(String.localized("Session monitor")) {
                toggleRow(
                    String.localized("Show sessions on the rail"),
                    subtitle: String.localized("A ring after your accounts. Point at it for every session and what it is doing."),
                    isOn: Binding(get: { settings.isEnabled }, set: { settings.isEnabled = $0 })
                )
                SettingsRowDivider()
                toggleRow(
                    String.localized("Keep the rail out while a session is active"),
                    subtitle: String.localized("Instead of hiding to its sliver while a session is running or waiting for you."),
                    isOn: Binding(get: { settings.keepsRailOpenWhileActive }, set: { settings.keepsRailOpenWhileActive = $0 })
                )
                SettingsRowDivider()
                toggleRow(
                    String.localized("Animated mark in the sessions ring"),
                    subtitle: nil,
                    isOn: Binding(get: { settings.showsBotMark }, set: { settings.showsBotMark = $0 })
                )
            }

            SettingsGroup(String.localized("Sources")) {
                ForEach(Array(SessionSource.allCases.enumerated()), id: \.element) { index, source in
                    if index > 0 { SettingsRowDivider() }
                    SettingsRow(
                        source.displayName,
                        subtitle: subtitle(for: source),
                        icon: source.provider?.iconResource
                    ) {
                        Toggle(source.displayName, isOn: Binding(
                            get: { settings.reads(source) },
                            set: { settings.setReads($0, source) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            piDesktopGroup

            visibilityGroup(
                String.localized("Hidden until the next turn ends"),
                entries: settings.hidden,
                empty: String.localized("No hidden sessions")
            )
            visibilityGroup(
                String.localized("Archived"),
                entries: settings.archived,
                empty: String.localized("No archived sessions")
            )

            Text(localized: "Hiding and archiving only change what Pulsession shows. The conversations themselves are not touched.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            String.localized("Restart PI-Desktop with its control port on?"),
            isPresented: $confirmsRelaunch
        ) {
            Button(String.localized("Restart PI-Desktop"), role: .destructive) { relaunch() }
            Button(String.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(localized: "PI-Desktop quits and opens again. A turn that is running stops. The port only listens on this Mac.")
        }
    }

    private var piDesktopGroup: some View {
        SettingsGroup(String.localized("PI-Desktop")) {
            toggleRow(
                String.localized("Use PI-Desktop control"),
                subtitle: String.localized("When PI-Desktop serves its local control port: open the session itself on click, and read approvals exactly."),
                isOn: Binding(get: { settings.usesPiDesktopControl }, set: { settings.usesPiDesktopControl = $0 })
            )
            SettingsRowDivider()
            SettingsRow(String.localized("Control port"), subtitle: controlStatus) {
                Button(isRelaunching ? String.localized("Restarting…") : String.localized("Restart with control on")) {
                    confirmsRelaunch = true
                }
                .disabled(isRelaunching || monitor.isControlReady || PiDesktopLauncher.applicationURL == nil)
            }
            if let version = monitor.piSchemaVersion, version != PiDesktopSessionReader.knownSchemaVersion {
                SettingsRowDivider()
                SettingsRow(
                    String.localized("Data format"),
                    subtitle: String.localized("PI-Desktop's data format has changed since this version of Pulsession. Some sessions may be missing or out of date.")
                ) {
                    Text(verbatim: "\(version) / \(PiDesktopSessionReader.knownSchemaVersion)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var controlStatus: String {
        if relaunchFailed { return String.localized("PI-Desktop could not be restarted.") }
        if PiDesktopLauncher.applicationURL == nil { return String.localized("PI-Desktop is not installed.") }
        if monitor.isControlReady { return String.localized("Ready.") }
        if !PiDesktopLauncher.isRunning { return String.localized("PI-Desktop is not running.") }
        return String.localized("Off. PI-Desktop was started without it.")
    }

    private func relaunch() {
        isRelaunching = true
        relaunchFailed = false
        Task {
            let started = await PiDesktopLauncher.relaunchWithControl()
            // The port comes up a moment after the window does.
            try? await Task.sleep(for: .seconds(3))
            isRelaunching = false
            relaunchFailed = !started
            monitor.refreshNow()
        }
    }

    private func subtitle(for source: SessionSource) -> String {
        switch source {
        case .piDesktop: String.localized("Reads ~/.pi-desktop, without writing to it.")
        case .claudeCode: String.localized("Reads ~/.claude/projects from the last day.")
        case .codex: String.localized("Reads ~/.codex/sessions from the last day.")
        }
    }

    private func toggleRow(_ title: String, subtitle: String?, isOn: Binding<Bool>) -> some View {
        SettingsRow(title, subtitle: subtitle) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    /// "my-app · Claude Code", or nothing when neither is known.
    private static func detail(of entry: SessionVisibilityEntry) -> String? {
        let parts = [entry.project, entry.source?.displayName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func visibilityGroup(_ title: String, entries: [SessionVisibilityEntry], empty: String) -> some View {
        SettingsGroup(title) {
            if entries.isEmpty {
                SettingsRow(empty) { EmptyView() }
            } else {
                ForEach(Array(entries.reversed().enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { SettingsRowDivider() }
                    SettingsRow(
                        entry.title,
                        subtitle: Self.detail(of: entry),
                        icon: entry.source?.provider?.iconResource
                    ) {
                        Button(String.localized("Restore")) { settings.restore(entry.id) }
                    }
                }
            }
        }
    }
}
