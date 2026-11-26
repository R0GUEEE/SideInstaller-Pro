import Combine
import Foundation

/// The Telegram side of the app: a list of channels to watch, a scan of what
/// they carry, and an AltStore-format source generated from the result.
///
/// **No account is used.** Reading a channel's posts requires either a signed-in
/// Telegram client (MTProto: an `api_id`/`api_hash` pair from my.telegram.org, a
/// phone-number login, its code and sometimes a 2FA password, then a session
/// kept on the device) or — as here — the public preview Telegram publishes at
/// `t.me/s/<channel>`. The preview is what this reads: recent posts, the file
/// names and sizes in them, and the post links. It cannot download a file, and
/// channels with previews switched off can't be read at all.
///
/// What this gives you is the useful part without the account: pick channels,
/// scan them several pages deep, and turn the result into a source file the app
/// (or SideStore, or AltStore) can load.
@MainActor
final class TelegramStudio: ObservableObject {

    static let shared = TelegramStudio()

    /// A channel the user chose to watch.
    struct Channel: Codable, Identifiable, Equatable {
        /// Without the `@`, as it appears in `t.me/<handle>`.
        var handle: String
        var title: String
        var enabled = true
        /// Walk every page the channel has, not just the recent ones.
        var allPages = true
        /// How many pages to walk when `allPages` is off. Each is about twenty
        /// posts.
        var pages = 3

        var id: String { handle.lowercased() }
        var link: URL { URL(string: "https://t.me/\(handle)")! }
    }

    /// What one scan found.
    struct Result: Identifiable {
        let channel: String
        var entries: [MarketEntry] = []
        var error: String?
        var scanned: Int = 0

        var id: String { channel }
    }

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var results: [Result] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanNote: String?
    /// Exports imported from Telegram Desktop, mapped to the same results.
    @Published private(set) var imports: [Result] = []
    /// Set after a scan produces a source file.
    @Published private(set) var generated: GeneratedSource?

    struct GeneratedSource {
        let url: URL
        let apps: Int
        let releases: Int
        let generatedAt: Date
    }

    private static let defaultsKey = "telegram.channels.v1"

    private init() {
        channels = Self.load()
    }

    // MARK: - Channels

    /// Adds `t.me/<handle>` (or a bare handle). Returns a message when it can't.
    @discardableResult
    func add(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)
        var handle: String?
        if let url, let parsed = TelegramSource.channel(from: url) {
            handle = parsed
        } else if !trimmed.contains("/") && !trimmed.contains(" ") {
            handle = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        }
        guard let handle, !handle.isEmpty else {
            return L("That isn't a Telegram channel. Paste a t.me/<channel> link, or just the channel's name.")
        }
        guard !channels.contains(where: { $0.id == handle.lowercased() }) else {
            return L("@%@ is already in the list.", handle)
        }
        channels.append(Channel(handle: handle, title: "@" + handle,
                                allPages: true,
                                pages: AppSettings.shared.defaultPages))
        save()
        return nil
    }

    func remove(_ id: String) {
        channels.removeAll { $0.id == id }
        results.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].enabled = enabled
        save()
    }

    func setPages(_ pages: Int, for id: String) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].pages = min(max(pages, 1), 40)
        save()
    }

    func setAllPages(_ all: Bool, for id: String) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].allPages = all
        save()
    }

    /// With "every page" on, this is the walk's backstop — configurable in
    /// Settings (forty pages is about eight hundred posts), and the reader stops
    /// earlier when a page brings nothing new.
    static var allPageLimit: Int { max(5, AppSettings.shared.allPagesLimit) }

    // MARK: - The directory

    /// Channels worth adding, grouped. A channel can be added from here in one
    /// tap; the free-form field stays for anything not listed.
    ///
    /// These are *public* channels with existing IPA content, not "your joined
    /// channels" — listing what your account is in requires a signed-in
    /// Telegram client, which this build doesn't have.
    struct DirectoryGroup: Identifiable {
        let title: String
        let note: String?
        let channels: [DirectoryChannel]

        var id: String { title }
    }

    struct DirectoryChannel: Identifiable {
        let handle: String
        let name: String
        let detail: String
        /// Measured when this list was written: does the channel publish a
        /// web preview, or does it only come through the bridge?
        let readable: Bool

        var id: String { handle.lowercased() }
        var link: URL { URL(string: "https://t.me/\(handle)")! }
    }

    static let directory: [DirectoryGroup] = [
        DirectoryGroup(title: L("Working now"), note: L("Publish a web preview, and the bridge carries their files."), channels: [
            DirectoryChannel(handle: "ipahub", name: "ipahub",
                             detail: L(".ipa attachments with sizes; opens the post to download."), readable: true),
            DirectoryChannel(handle: "ipaomtk", name: "IPAOMTK",
                             detail: L("Write-ups linking its own site; the bridge exposes the files."), readable: true),
        ]),
        DirectoryGroup(title: L("Through the bridge"), note: L("No web preview — Telegram alone can't read these. The RSS bridge can, and it links the .ipa files directly."), channels: [
            DirectoryChannel(handle: "blatants", name: "Blatant's iPA Library",
                             detail: L("Tweaked IPAs, updated automatically. Files download directly."), readable: false),
            DirectoryChannel(handle: "binnichtaktivsipas", name: "binnichtaktiv's iPA Library",
                             detail: L("Attachments; files download directly through the bridge."), readable: false),
            DirectoryChannel(handle: "iOS_Randy420", name: "iOS Tutorials + App Cracks",
                             detail: L("Mixed posts, some with attachments; the bridge picks out the .ipa ones."), readable: false),
        ]),
        DirectoryGroup(title: L("Add your own"), note: L("Any public channel works: paste t.me/<channel> below. A private channel (t.me/c/…) has no public page at all."), channels: []),
    ]

    /// True when the handle is already in the list.
    func contains(_ handle: String) -> Bool {
        channels.contains { $0.id == handle.lowercased() }
    }

    // MARK: - Scanning

    /// Reads every enabled channel, several pages deep, and keeps what it finds.
    func scan() async {
        guard !isScanning else { return }
        // Every channel, enabled or not, is left to the user's switches; the
        // scan reads all of them so a channel never silently drops out.
        let wanted = channels.filter(\.enabled)
        guard !wanted.isEmpty else {
            scanNote = L("No channels are enabled.")
            return
        }
        isScanning = true
        scanNote = nil
        var found: [Result] = []
        for channel in wanted {
            do {
                let read = try await TelegramSource.entries(channel: channel.handle,
                                                            pages: channel.allPages ? Self.allPageLimit : channel.pages)
                if let index = channels.firstIndex(where: { $0.id == channel.id }),
                   channels[index].title != read.name {
                    channels[index].title = read.name
                    save()
                }
                found.append(Result(channel: channel.handle, entries: read.entries,
                                    error: nil, scanned: read.entries.count))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                found.append(Result(channel: channel.handle, error: message))
            }
        }
        results = found
        isScanning = false
        let total = found.reduce(0) { $0 + $1.entries.count }
        let failed = found.filter { $0.error != nil }.count
        scanNote = failed == 0
            ? L("Found %ld app(s) across %ld channel(s).", total, found.count)
            : L("Found %ld app(s); %ld channel(s) couldn't be read.", total, failed)
    }

    /// Every scanned or imported entry, as one list.
    var allEntries: [MarketEntry] {
        (results + imports).flatMap(\.entries)
    }

    /// Reads a Telegram Desktop export and adds its apps to the list.
    @discardableResult
    func importExport(_ json: URL) -> String? {
        do {
            let summary = try TelegramExport.read(json)
            imports.removeAll { $0.id == summary.channel }
            imports.append(Result(channel: summary.channel, entries: summary.entries,
                                  error: nil, scanned: summary.messages))
            let missing = summary.missingFiles
            scanNote = missing == 0
                ? L("Imported %ld app(s) from \"%@\".", summary.entries.count, summary.channel)
                : L("Imported %ld app(s) from \"%@\"; %ld file(s) weren't in the export folder.",
                    summary.entries.count, summary.channel, missing)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    // MARK: - The account's channel list

    /// What the last whole-account export listed.
    @Published private(set) var discovery: TelegramDiscovery.Account?

    /// Reads a full Telegram Desktop export and keeps the channel list it
    /// carries. Returns a message on failure, nil when it worked.
    func scanAccount(_ json: URL) -> String? {
        do {
            let account = try TelegramDiscovery.read(json)
            discovery = account
            scanNote = L("Found %ld channel(s) in the export, %ld of them with .ipa files.",
                         account.found.count, account.found.filter { $0.ipaCount > 0 }.count)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Adds the discovered channels that have a public handle — the only ones
    /// this app can read without an account. Returns added and skipped counts.
    @discardableResult
    func addDiscovered(_ items: [TelegramDiscovery.Found]) -> (added: Int, skipped: Int) {
        var added = 0
        var skipped = 0
        for item in items {
            guard let handle = item.handle, !handle.isEmpty else {
                skipped += 1
                continue
            }
            if add(handle) == nil { added += 1 } else { skipped += 1 }
        }
        if added > 0 {
            scanNote = L("Added %ld channel(s) from the export; %ld kept out.", added, skipped)
        }
        discovery = nil
        return (added, skipped)
    }

    func removeImport(_ id: String) {
        imports.removeAll { $0.id == id }
    }

    // MARK: - The generated source

    /// Writes the scan to an AltStore-format document in Documents and reports
    /// where it is. The file is what a "live source" needs: the app can load it
    /// through a `file://` URL, and the same JSON can be hosted anywhere and
    /// given to SideStore or AltStore.
    @discardableResult
    func generateSource() -> GeneratedSource? {
        let entries = allEntries
        guard !entries.isEmpty else {
            scanNote = L("Nothing to generate yet — scan first.")
            return nil
        }
        let document = Self.document(from: entries)
        guard let data = try? JSONSerialization.data(withJSONObject: document,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        let directory = IPALibrary.documentsDir.appendingPathComponent("Telegram", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("telegram-source.json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            scanNote = L("Couldn't write the source: %@", error.localizedDescription)
            return nil
        }
        let releases = entries.reduce(0) { $0 + $1.versions.count }
        let source = GeneratedSource(url: url, apps: entries.count, releases: releases,
                                     generatedAt: Date())
        generated = source
        return source
    }

    /// The AltStore v2 document: every release each channel produced, in the
    /// shape the app's own parser reads back.
    private static func document(from entries: [MarketEntry]) -> [String: Any] {
        var apps: [[String: Any]] = []
        for entry in entries {
            var versions: [[String: Any]] = []
            for version in entry.versions {
                var fields: [String: Any] = [
                    "version": version.version ?? "1.0",
                    "downloadURL": version.url,
                ]
                if let date = version.date {
                    fields["date"] = ISO8601DateFormatter().string(from: date)
                }
                if let size = version.size { fields["size"] = size }
                versions.append(fields)
            }
            guard let newest = versions.first else { continue }
            var app: [String: Any] = [
                "name": entry.name,
                // Telegram doesn't publish bundle IDs; this keys the app and is
                // what the generated source lists it under.
                "bundleIdentifier": entry.id,
                "developerName": entry.developer ?? "Telegram",
                "subtitle": entry.subtitle ?? "",
                "localizedDescription": entry.subtitle ?? "",
                "category": "Telegram",
                "versions": versions,
                // Kept for readers that only look at the top-level release.
                "version": newest["version"] ?? "1.0",
                "downloadURL": newest["downloadURL"] ?? "",
            ]
            if let icon = entry.icon { app["iconURL"] = icon }
            apps.append(app)
        }
        return [
            "name": "SideInstaller Telegram",
            "identifier": "com.sideinstaller.telegram",
            "subtitle": L("Generated from your Telegram channels"),
            "description": L("Built by SideInstaller on %@. Telegram serves its files inside its app, so an entry opens its post unless the channel links the .ipa directly.",
                             Date().formatted(date: .abbreviated, time: .shortened)),
            "iconURL": "",
            "tintColor": "#0A84FF",
            "apps": apps,
        ]
    }

    /// The link that adds the generated source to SideInstaller itself.
    var sourceLink: URL? {
        guard let generated else { return nil }
        var components = URLComponents()
        components.scheme = "sideinstaller"
        components.host = "source"
        components.queryItems = [URLQueryItem(name: "url", value: generated.url.absoluteString)]
        return components.url
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [Channel] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let channels = try? JSONDecoder().decode([Channel].self, from: data)
        else { return [] }
        return channels
    }
}
