import SwiftUI
import UIKit

/// The sections added to Settings for sources, the local server and storage —
/// everything that used to be a constant in the code.
extension SettingsView {

    // MARK: - Sources

    @ViewBuilder
    var sourcesSection: some View {
        Section {
            NavigationLink {
                TelegramSettingsView()
            } label: {
                Label(L("Telegram channels"), systemImage: "paperplane")
            }
            NavigationLink {
                MarketplaceSettingsView()
            } label: {
                Label(L("Marketplace"), systemImage: "square.grid.2x2")
            }
            NavigationLink {
                RenewalSettingsView()
            } label: {
                Label(L("Renewals"), systemImage: "clock.arrow.circlepath")
            }
            NavigationLink {
                StorageSettingsView()
            } label: {
                Label(L("Storage"), systemImage: "internaldrive")
            }
        } header: {
            Text(L("Sources & storage"))
        } footer: {
            Text(L("How sources are read, how the marketplace opens, and what the app keeps on disk."))
        }
    }

    // MARK: - Diagnostics

    @ViewBuilder
    var diagnosticsSection: some View {
        Section {
            Button {
                shareDiagnostics()
            } label: {
                Label(L("Export diagnostics"), systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                AppSettings.shared.reset()
                showNote(L("Settings reset to their defaults."))
            } label: {
                Label(L("Reset these settings"), systemImage: "arrow.uturn.backward")
            }
        } header: {
            Text(L("Diagnostics"))
        } footer: {
            Text(L("Diagnostics is a text file: these settings, the storage report, the source list and the current log. It contains no Apple ID and no passwords. Resetting settings leaves accounts, certificates and sources alone."))
        }
    }

    private func shareDiagnostics() {
        var lines: [String] = []
        lines.append("SideInstaller diagnostics")
        lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .standard))")
        lines.append("iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Build: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        lines.append("")
        lines.append("Settings")
        for entry in AppSettings.shared.summary { lines.append("  \(entry.key): \(entry.value)") }
        lines.append("")
        lines.append("Storage")
        for item in StorageReport.items() { lines.append("  \(item.name): \(item.sizeText)") }
        lines.append("")
        lines.append("Sources")
        for source in SourceStore.shared.sources {
            let state = source.error.map { "error: \($0)" } ?? "\(source.appCount) apps"
            lines.append("  \(source.name.isEmpty ? source.id : source.name): \(state)")
        }
        lines.append("")
        lines.append("Telegram")
        for channel in TelegramStudio.shared.channels {
            lines.append("  @\(channel.handle): \(channel.allPages ? "all pages" : "\(channel.pages) pages")")
        }
        lines.append("")
        lines.append("Log (last 300 lines)")
        lines.append(contentsOf: Engine.shared.logText().split(separator: "\n").suffix(300).map(String.init))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sideinstaller-diagnostics.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        shareFile(url)
    }

    private func shareFile(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var controller = root
        while let presented = controller.presentedViewController { controller = presented }
        controller.present(UIActivityViewController(activityItems: [url], applicationActivities: nil),
                           animated: true)
    }
}

// MARK: - Telegram

/// The Telegram decisions: which readers to use, how deep to scan, and whether
/// the local server and background refreshes run.
struct TelegramSettingsView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var server = LocalSourceServer.shared
    @ObservedObject private var keepAlive = BackgroundKeepAlive.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.bridgeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Use the RSS bridge"))
                        Text(L("Reads channels that publish no web preview, and links the .ipa files directly. Without it those channels can't be read at all."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.scanOnLaunch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Scan when the app opens"))
                        Text(L("Reads every enabled channel on launch. Slower to start, always current."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("Reading"))
            }

            Section {
                Stepper(value: $settings.allPagesLimit, in: 5...100, step: 5) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Every-page limit: %ld", settings.allPagesLimit))
                        Text(L("Preview pages to walk when a channel is set to scan every page — about twenty posts each."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.defaultPages, in: 1...40) {
                    Text(L("Default depth: %ld page(s)", settings.defaultPages))
                }
            } header: {
                Text(L("Depth"))
            }

            Section {
                Toggle(isOn: $settings.backgroundRefresh) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Background refresh"))
                        Text(L("Asks iOS to wake the app now and then to rescan and refresh the generated source. iOS decides when, and may skip it."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.keepAliveOnBackground) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Grace period after backgrounding"))
                        Text(L("Holds the app for about thirty seconds so a client can finish fetching from the local server."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let last = keepAlive.lastRefresh {
                    LabeledContent(L("Last background scan"),
                                   value: last.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Text(L("Background"))
            } footer: {
                Text(L("Silent audio and location sessions would keep the app alive indefinitely. They aren't used: they misdeclare what the app does, drain the battery, and are what gets a signing certificate pulled."))
            }

            Section {
                Toggle(isOn: $settings.serverAutoStart) {
                    Text(L("Start the local server with the app"))
                }
                Stepper(value: $settings.serverPort, in: 1024...65535) {
                    LabeledContent(L("Port"), value: "\(settings.serverPort)")
                }
                LabeledContent(L("Server"), value: serverStateText)
                if let url = server.url {
                    LabeledContent(L("Source URL"), value: url.absoluteString)
                }
            } header: {
                Text(L("Local server"))
            } footer: {
                Text(L("Bound to 127.0.0.1: only apps on this iPhone can reach it, and it stops when the app is suspended."))
            }
        }
        .navigationTitle(L("Telegram channels"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var serverStateText: String {
        switch server.state {
        case .stopped:              return L("Stopped")
        case .starting:             return L("Starting…")
        case .running(let port):    return L("Running on %ld", port)
        case .failed(let message):  return message
        }
    }
}

// MARK: - Marketplace

/// How the marketplace opens, and what it lists.
struct MarketplaceSettingsView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Sort by"), selection: $settings.marketplaceSort) {
                    Text(L("Name")).tag("name")
                    Text(L("Newest")).tag("newest")
                    Text(L("Oldest")).tag("oldest")
                    Text(L("Size")).tag("size")
                }
                Toggle(isOn: $settings.showNonDirectEntries) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Show entries that open another app"))
                        Text(L("Telegram posts, and anything else whose link leads to a page rather than a file. Off leaves only what installs here."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("Listing"))
            } footer: {
                Text(L("The filter and search box override these while the marketplace is open."))
            }
        }
        .navigationTitle(L("Marketplace"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Storage

/// What the app keeps on disk, with a way to empty each part.
struct StorageSettingsView: View {
    @EnvironmentObject private var loc: Localizer
    @State private var items: [StorageReport.Item] = []
    @State private var pendingClear: StorageReport.Item?

    var body: some View {
        Form {
            Section {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(item.sizeText)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            pendingClear = item
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(item.bytes == 0)
                    }
                }
            } header: {
                Text(L("Regenerable data"))
            } footer: {
                Text(L("Total %@. All of it is rebuilt on demand: indexes by refreshing a source, icons by reading the device, generated sources by scanning. Your .ipa library, pairing files and certificates are not in this list.", StorageReport.totalText(items)))
            }
        }
        .navigationTitle(L("Storage"))
        .navigationBarTitleDisplayMode(.inline)
        // Four directory walks, including every cached app icon: measured off
        // the main actor so opening Storage can't freeze the sheet.
        .onAppear { Task { await measure() } }
        .confirmationDialog(L("Clear this data?"),
                            isPresented: Binding(get: { pendingClear != nil },
                                                 set: { if !$0 { pendingClear = nil } }),
                            presenting: pendingClear) { item in
            Button(L("Clear %@", item.name), role: .destructive) {
                StorageReport.clear(item)
                pendingClear = nil
                Task { await measure() }
            }
            Button(L("Cancel"), role: .cancel) { pendingClear = nil }
        } message: { item in
            Text(L("%@ (%@) is deleted. It's rebuilt the next time it's needed.", item.name, item.sizeText))
        }
    }

    private func measure() async {
        items = await Task.detached(priority: .utility) { StorageReport.items() }.value
    }
}

// MARK: - Renewals

/// Keeping sideloaded apps from expiring: what the background pass does, and
/// what it can't.
struct RenewalSettingsView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var renewals = AutoResign.shared

    @State private var note: String?
    @State private var isRunning = false
    /// Worked out when the screen appears: matching profiles is property-list
    /// parsing, not something to do on every layout pass.
    @State private var pending = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { settings.autoResignEnabled },
                                     set: { settings.autoResignEnabled = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Renew apps before they expire"))
                        Text(L("A free Apple ID's profile lasts seven days. This wakes the app in the background and re-signs the ones that are close, so they keep launching."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: Binding(get: { settings.autoResignHoursBefore },
                                       set: { settings.autoResignHoursBefore = $0 }),
                        in: 6...72, step: 6) {
                    Text(L("Renew within %ld hours of expiry", settings.autoResignHoursBefore))
                }
                LabeledContent(L("Right now"), value: pending)
            } header: {
                Text(L("Schedule"))
            } footer: {
                Text(L("iOS decides when a background app may run, and may skip it entirely. Renewing also needs a live Apple session: if sign-in is waiting on a verification code, the pass stops and tells you to open the app."))
            }

            Section {
                Toggle(isOn: $settings.askBeforeAppIDCost) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Ask before using an App ID"))
                        Text(L("On, a custom .ipa stops for a yes before it registers an App ID. Off — the default — signing finishes and installs in one go."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("Installing"))
            }

            Section {
                Button {
                    isRunning = true
                    Task {
                        note = await renewals.run(interactive: true)
                        isRunning = false
                    }
                } label: {
                    HStack {
                        Label(L("Renew expiring apps now"), systemImage: "arrow.clockwise")
                        Spacer()
                        if isRunning { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isRunning || renewals.isRunning)

                if let last = renewals.lastRun {
                    LabeledContent(L("Last pass"),
                                   value: last.formatted(date: .abbreviated, time: .shortened))
                }
                if let summary = note ?? renewals.lastSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Now"))
            }
        }
        .navigationTitle(L("Renewals"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { pending = renewals.pendingDescription() }
        .onChange(of: settings.autoResignHoursBefore) { _, _ in
            pending = renewals.pendingDescription()
        }
    }
}
