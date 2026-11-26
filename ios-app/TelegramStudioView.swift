import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Telegram screen: which channels to watch, a scan of what they carry, and
/// the source file built from it.
///
/// It states plainly what it can and can't do. Reading a channel needs either a
/// signed-in Telegram client or the channel's public preview; this uses the
/// preview, so it works without an account, can't download files, and can't see
/// channels that turned previews off.
struct TelegramStudioView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var studio = TelegramStudio.shared
    @ObservedObject private var credentials = TelegramCredentials.shared
    @ObservedObject private var server = LocalSourceServer.shared
    @ObservedObject private var keepAlive = BackgroundKeepAlive.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var newChannel = ""
    @State private var addError: String?
    @State private var showAccountInfo = false
    @State private var showCredentials = false
    @State private var showExportPicker = false
    @State private var importError: String?
    /// The whole-account export: its picker, its error, and its sheet.
    @State private var showDiscoveryPicker = false
    @State private var showDiscovery = false
    @State private var discoveryError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    accountCard
                    addCard
                    discoveryCard
                    channelCard
                    scanCard
                    exportCard
                    sourceCard
                    serverCard
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("Telegram"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, serverRunning || keepAlive.isExtending {
                    keepAlive.extendForBackground()
                }
            }
            .sheet(isPresented: $showAccountInfo) { accountExplanation }
            .sheet(isPresented: $showCredentials) {
                TelegramCredentialsView().environmentObject(loc)
            }
            .sheet(isPresented: $showDiscoveryPicker) {
                FileImporterRepresentableView(allowedContentTypes: [.json]) { urls in
                    guard let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    discoveryError = studio.scanAccount(url)
                    if discoveryError == nil { showDiscovery = true }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showDiscovery) {
                if let account = studio.discovery {
                    TelegramDiscoverySheet(account: account, studio: studio)
                }
            }
            .sheet(isPresented: $showExportPicker) {
                FileImporterRepresentableView(allowedContentTypes: [.json]) { urls in
                    guard let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    importError = studio.importExport(url)
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: Account

    /// The truth about signing in, rather than a button that can't work.
    private var accountCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L("Account"), systemImage: "person.crop.circle.badge.questionmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(credentials.isConfigured
                         ? L("API credentials saved")
                         : L("No API credentials"))
                        .font(.caption)
                        .foregroundStyle(AnyShapeStyle(credentials.isConfigured ? Color.green : Color.secondary))
                }
                Text(L("SideInstaller reads channels through Telegram's public previews — no account, no phone number, no session on this iPhone. A channel that has previews switched off can't be read this way, and files always download inside Telegram."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(credentials.isConfigured
                           ? L("API credentials")
                           : L("Set up API credentials")) { showCredentials = true }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                    Button(L("What signing in would take")) { showAccountInfo = true }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var accountExplanation: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("Reading a channel as your Telegram account"))
                        .font(.headline)
                    Text(L("Telegram's API isn't open. A signed-in client is an MTProto session, and building one means:"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach([
                            L("an api_id and api_hash from my.telegram.org, for this app"),
                            L("a phone-number login: Telegram sends a code to your other devices or by SMS"),
                            L("the 2FA password, for accounts that have one"),
                            L("a session key kept on this device — a credential as sensitive as your Apple ID"),
                            L("a file download path, because a session is the only thing that can fetch a file"),
                        ], id: \.self) { line in
                            Label(line, systemImage: "circle.fill")
                                .font(.caption)
                                .labelStyle(BulletLabelStyle())
                        }
                    }
                    Text(L("That is a real piece of work, and it puts a Telegram session in the app. The channel selection, deep scan and generated source in this screen don't need any of it — they work now. If you want the signed-in version, it can be built next, as its own step."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("Signing in"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Directory

    /// The channels to choose from, grouped and drillable, with the free-form
    /// field underneath for anything not listed.
    private var addCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L("Add a channel"), systemImage: "list.bullet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(TelegramStudio.directory) { group in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            if let note = group.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(group.channels) { channel in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(channel.name)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Text("@\(channel.handle) · \(channel.detail)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 4)
                                    if studio.contains(channel.handle) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.footnote)
                                    } else {
                                        Button(L("Add")) {
                                            addError = studio.add(channel.handle)
                                        }
                                        .font(.caption.weight(.semibold))
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 6) {
                            Text(group.title)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if !group.channels.isEmpty {
                                Text("\(group.channels.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Divider().opacity(0.15)

                HStack(spacing: 8) {
                    TextField("t.me/channel", text: $newChannel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.subheadline)
                    Button {
                        addError = studio.add(newChannel)
                        if addError == nil { newChannel = "" }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.accent2)
                    }
                    .buttonStyle(.plain)
                    .disabled(newChannel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .fieldBackground()

                if let addError {
                    Text(addError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(L("The list above is public channels with IPA content, checked when it was written. For your own account's channels, use Scan my whole Telegram below — it reads them out of a Telegram Desktop export."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Whole account

    /// The account's own channel list, from a full Telegram Desktop export.
    private var discoveryCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("Scan my whole Telegram"), systemImage: "person.crop.circle.badge.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(L("Telegram Desktop › Settings › Advanced › Export Telegram data, tick “include everything”, JSON. Pick the result.json here and every channel your account is in is listed — with how many .ipa files each carries — so they can be added in one go."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showDiscoveryPicker = true
                } label: {
                    Label(L("Choose the account's result.json"), systemImage: "doc.badge.plus")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let discoveryError {
                    Text(discoveryError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let account = studio.discovery {
                    HStack(spacing: 8) {
                        Text(L("%ld channel(s) found", account.found.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Review")) { showDiscovery = true }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.accent2)
                    }
                }
                Text(L("Only channels with a public @handle can be read from here without an account; the rest are listed so the list is complete."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Channels

    private var channelCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L("%ld channels", studio.channels.count), systemImage: "paperplane")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if studio.channels.isEmpty {
                    Text(L("No channels yet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(studio.channels) { channel in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(get: { channel.enabled },
                                                 set: { studio.setEnabled($0, for: channel.id) })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(channel.title.isEmpty ? "@\(channel.handle)" : channel.title)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text("@\(channel.handle)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            Button(role: .destructive) {
                                studio.remove(channel.id)
                            } label: {
                                Image(systemName: "trash").font(.footnote)
                            }
                            .buttonStyle(.borderless)
                        }
                        Toggle(isOn: Binding(get: { channel.allPages },
                                             set: { studio.setAllPages($0, for: channel.id) })) {
                            Text(L("Scan every page"))
                                .font(.caption2)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        if !channel.allPages {
                            Stepper(value: Binding(get: { channel.pages },
                                                   set: { studio.setPages($0, for: channel.id) }),
                                    in: 1...40) {
                                Text(L("%ld page(s) · ~%ld posts", channel.pages, channel.pages * 20))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if channel.id != studio.channels.last?.id { Divider().opacity(0.15) }
                }
            }
        }
    }

    // MARK: Scan

    private var scanCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        Task { await studio.scan() }
                    } label: {
                        Label(studio.isScanning ? L("Scanning…") : L("Scan channels"),
                              systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(studio.isScanning || studio.channels.allSatisfy { !$0.enabled })
                }
                if studio.isScanning { ProgressView().controlSize(.small) }
                if let note = studio.scanNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(studio.results) { result in
                    HStack(alignment: .top, spacing: 8) {
                        SourceIcon(url: result.entries.first?.iconURL,
                                   side: 26, fallback: "paperplane.fill", corner: 7)
                        Text("@\(result.channel)")
                            .font(.caption.monospaced())
                        Spacer(minLength: 4)
                        if let error = result.error {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
                        } else {
                            Text(L("%ld apps", result.entries.count))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Export import

    /// The offline path to a whole channel: Telegram Desktop's export has every
    /// message and the files themselves.
    private var exportCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("Import a channel export"), systemImage: "tray.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(L("Telegram Desktop › open the channel › ⋮ › Export chat history › JSON. Pick its result.json here: every .ipa it lists is added, and files that came with the export install straight from disk — no account, and it works for channels whose previews are off."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showExportPicker = true
                } label: {
                    Label(L("Choose result.json"), systemImage: "doc.badge.plus")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(studio.imports) { imported in
                    HStack(spacing: 8) {
                        Text("@\(imported.channel)")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(L("%ld apps", imported.entries.count))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            studio.removeImport(imported.id)
                        } label: {
                            Image(systemName: "trash").font(.footnote)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: Source

    private var sourceCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("Live source"), systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(L("Turns the scan into an AltStore-format source, written to this app's Documents as Telegram/telegram-source.json. Add it here with the link below, or copy the JSON and host it anywhere for SideStore or AltStore. Regenerate it after a scan to keep it current."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if let generated = studio.generateSource() {
                        UIPasteboard.general.string = generated.url.absoluteString
                    }
                } label: {
                    Label(L("Generate the source file"), systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(studio.allEntries.isEmpty)

                if let generated = studio.generated {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("%ld apps · %ld releases · %@", generated.apps, generated.releases,
                               generated.generatedAt.formatted(date: .omitted, time: .shortened)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(generated.url.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 8) {
                        Button {
                            UIPasteboard.general.string = generated.url.absoluteString
                        } label: {
                            Label(L("Copy URL"), systemImage: "doc.on.doc")
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            share(generated.url)
                        } label: {
                            Label(L("Share JSON"), systemImage: "square.and.arrow.up")
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: Local server

    /// The source served over loopback, for clients that want a URL.
    private var serverCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L("Local server"), systemImage: "server.rack")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if case .running(let port) = server.state {
                        Text(L("127.0.0.1:%ld", port))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.green)
                    }
                }
                Text(L("Serves the generated source over loopback, rebuilt on every request, so anything on this iPhone can add it as a URL — SideStore and AltStore included. It stops when SideInstaller leaves the foreground; iOS doesn't keep a socket alive in the background."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        if case .running = server.state { server.stop() } else { server.start() }
                    } label: {
                        Label(serverRunning ? L("Stop") : L("Start"),
                              systemImage: serverRunning ? "stop.circle" : "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if let url = server.url { UIPasteboard.general.string = url.absoluteString }
                    } label: {
                        Label(L("Copy URL"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(server.url == nil)
                }

                if let url = server.url {
                    Text(url.absoluteString)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if case .failed(let message) = server.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if server.served > 0 {
                    Text(L("%ld request(s) served.", server.served))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Divider().opacity(0.15)
                Text(L("Background: iOS gives about thirty seconds after you leave the app, then wakes it on its own schedule to rescan. Silent audio and location sessions would keep it alive indefinitely — that's background-mode abuse, so it isn't used here."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = keepAlive.lastRefresh {
                    Text(L("Last background scan %@ · %ld app(s)",
                           last.formatted(date: .abbreviated, time: .shortened),
                           keepAlive.lastRefreshApps ?? 0))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var serverRunning: Bool {
        if case .running = server.state { return true }
        return false
    }

    private func share(_ url: URL) {
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

/// A small dot instead of an SF Symbol, for a plain bulleted list.
private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: 4))
                .foregroundStyle(.tertiary)
            configuration.title
        }
    }
}

// MARK: - API credentials

/// Telegram's own per-app registration, laid out as the three steps it is.
///
/// The two values come from my.telegram.org/apps and are what any Telegram
/// client needs before it can log in — this app's, or Telegram's own.
struct TelegramCredentialsView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var credentials = TelegramCredentials.shared
    @Environment(\.dismiss) private var dismiss

    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PanelCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(L("1 · Register an application"), systemImage: "1.circle.fill")
                                .font(.subheadline.weight(.semibold))
                            Text(L("Open Telegram's developer page and sign in with your phone number. Create an app — the name and platform are yours to choose — and it shows an api_id (a number) and an api_hash (32 letters and digits)."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                UIApplication.shared.open(TelegramCredentials.registrationURL)
                            } label: {
                                Label(L("Open my.telegram.org/apps"), systemImage: "safari")
                                    .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    PanelCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(L("2 · Paste them here"), systemImage: "2.circle.fill")
                                .font(.subheadline.weight(.semibold))
                            TextField(L("api_id"), text: $apiID)
                                .keyboardType(.numberPad)
                                .font(.subheadline.monospaced())
                                .fieldBackground()
                            TextField(L("api_hash"), text: $apiHash)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.subheadline.monospaced())
                                .fieldBackground()
                            if let error = credentials.lastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if saved {
                                Label(L("Saved to the Keychain on this iPhone."), systemImage: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            Button {
                                saved = credentials.save(apiID: apiID, apiHash: apiHash)
                            } label: {
                                Label(L("Save credentials"), systemImage: "key.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(apiID.isEmpty || apiHash.isEmpty)
                            if credentials.isConfigured {
                                Button(role: .destructive) {
                                    credentials.clear()
                                    apiID = ""
                                    apiHash = ""
                                    saved = false
                                } label: {
                                    Text(L("Remove the saved credentials"))
                                        .font(.footnote.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    PanelCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L("3 · The login itself"), systemImage: "3.circle.fill")
                                .font(.subheadline.weight(.semibold))
                            Text(L("Credentials are what a Telegram client needs to start; the login that follows is an MTProto session — a code sent to your other devices, a 2FA password if you have one, and a session key kept here. That client isn't in this build yet, so the credentials are stored and nothing else uses them."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L("Until then the studio reads public previews, and a Telegram Desktop export imports a whole channel offline."))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("Telegram API"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .onAppear {
                if let existing = credentials.credentials {
                    apiID = String(existing.apiID)
                    apiHash = existing.apiHash
                }
            }
        }
    }
}


/// The channels a whole-account export listed, with the ones worth adding
/// picked already: public, and carrying `.ipa` files.
private struct TelegramDiscoverySheet: View {
    let account: TelegramDiscovery.Account
    @ObservedObject var studio: TelegramStudio

    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    @State private var picked: Set<String>

    init(account: TelegramDiscovery.Account, studio: TelegramStudio) {
        self.account = account
        _studio = ObservedObject(wrappedValue: studio)
        _picked = State(initialValue: Set(account.found
            .filter { $0.isAddable && $0.ipaCount > 0 }
            .map(\.id)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    SummaryLine(account: account, picked: picked.count).cascadeItem(0)
                    ForEach(account.found) { channel in
                        row(channel)
                        Divider().opacity(0.12).padding(.leading, 34)
                    }
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("Channels found"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button {
                        studio.addDiscovered(account.found.filter { picked.contains($0.id) })
                        dismiss()
                    } label: {
                        Text(picked.isEmpty ? L("Nothing picked") : L("Add %ld channel(s)", picked.count))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(picked.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                .background(.ultraThinMaterial)
            }
        }
    }

    private func row(_ channel: TelegramDiscovery.Found) -> some View {
        let already = channel.handle.map { studio.contains($0) } ?? false
        return Button {
            guard channel.isAddable, !already else { return }
            if picked.contains(channel.id) { picked.remove(channel.id) }
            else { picked.insert(channel.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: channel.isAddable
                      ? (picked.contains(channel.id) ? "checkmark.circle.fill" : "circle")
                      : "lock.circle")
                    .font(.footnote)
                    .foregroundStyle(channel.isAddable
                                     ? (picked.contains(channel.id) ? Theme.accent2 : Color.secondary)
                                     : Color.secondary.opacity(0.5))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(channel.handle.map { "@" + $0 } ?? L("no public handle"))
                            .lineLimit(1)
                        if channel.ipaCount > 0 {
                            Text("·")
                            Text(L("%ld .ipa", channel.ipaCount))
                        }
                        if already {
                            Text("·")
                            Text(L("added"))
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Text(channel.kind.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SummaryLine: View {
    let account: TelegramDiscovery.Account
    let picked: Int

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.title)
                    .font(.headline)
                Text(L("%ld channel(s) · %ld with .ipa files · %ld chosen",
                       account.found.count,
                       account.found.filter { $0.ipaCount > 0 }.count,
                       picked))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
