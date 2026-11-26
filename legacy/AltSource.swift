// Preserved from the pre-fork `feat/sources-and-ipa-inspector` branch, whose
// history has nothing in common with main's. It is kept for reference only and
// lives outside `ios-app/` because it declares its own `SourceStore`, which
// collides with the app's. The live source model is `ios-app/SourceParser.swift`.

import Foundation

/// An AltStore-format source: the JSON that AltStore, SideStore, Feather and
/// every other source-based sideloader read. SideInstaller loads one to browse
/// the apps it lists and install any of them, signed with your Apple ID, the
/// same way it installs anything else.
///
/// The format has two shapes in the wild and both are accepted: v2 keeps every
/// app's releases under `versions`, while v1 repeats the newest release as
/// top-level `version` / `downloadURL` / `size`. Fields a source leaves out are
/// simply absent, so every property here is optional except the name.
struct AltSource: Decodable, Identifiable {

    let name: String
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: String?
    let headerURL: String?
    let website: String?
    let tintColor: String?
    let featuredApps: [String]?
    let apps: [AltApp]
    let news: [AltNews]?

    /// Where it was fetched from; `SourceStore` fills this in.
    var sourceURL: URL?

    var id: String { identifier ?? name }

    private enum CodingKeys: String, CodingKey {
        case name, identifier, subtitle, description, iconURL, headerURL, website,
             tintColor, featuredApps, apps, news
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled source"
        identifier = try? container.decodeIfPresent(String.self, forKey: .identifier)
        subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        iconURL = try? container.decodeIfPresent(String.self, forKey: .iconURL)
        headerURL = try? container.decodeIfPresent(String.self, forKey: .headerURL)
        website = try? container.decodeIfPresent(String.self, forKey: .website)
        tintColor = try? container.decodeIfPresent(String.self, forKey: .tintColor)
        featuredApps = try? container.decodeIfPresent([String].self, forKey: .featuredApps)
        news = try? container.decodeIfPresent([AltNews].self, forKey: .news)
        // A source whose apps can't be read is an error worth showing, so this
        // one isn't swallowed like the rest.
        apps = (try? container.decodeIfPresent([AltApp].self, forKey: .apps)) .flatMap { $0 } ?? []
    }

    /// Apps worth listing: those with at least one downloadable release, sorted
    /// by name.
    var installableApps: [AltApp] {
        apps.filter { !$0.releases.isEmpty }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The icon as a URL, when the source gave something usable.
    var icon: URL? { URL(string: iconURL ?? "") }
}

/// One app in a source.
struct AltApp: Decodable, Identifiable {

    let name: String
    let bundleIdentifier: String?
    let developerName: String?
    let subtitle: String?
    let localizedDescription: String?
    let iconURL: String?
    let tintColor: String?
    let category: String?
    let screenshots: [String]?
    let versions: [AltVersion]?

    /// v1 repeats the newest release at the app's top level.
    let version: String?
    let downloadURL: String?
    let size: Int64?

    var id: String { (bundleIdentifier ?? name) + "@" + (iconURL ?? "") }

    private enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, subtitle, localizedDescription,
             iconURL, tintColor, category, screenshots, versions,
             version, downloadURL, size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled app"
        bundleIdentifier = try? container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        developerName = try? container.decodeIfPresent(String.self, forKey: .developerName)
        subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
        localizedDescription = try? container.decodeIfPresent(String.self, forKey: .localizedDescription)
        iconURL = try? container.decodeIfPresent(String.self, forKey: .iconURL)
        tintColor = try? container.decodeIfPresent(String.self, forKey: .tintColor)
        category = try? container.decodeIfPresent(String.self, forKey: .category)
        screenshots = try? container.decodeIfPresent([String].self, forKey: .screenshots)
        versions = try? container.decodeIfPresent([AltVersion].self, forKey: .versions)
        version = try? container.decodeIfPresent(String.self, forKey: .version)
        downloadURL = try? container.decodeIfPresent(String.self, forKey: .downloadURL)
        size = try? container.decodeIfPresent(Int64.self, forKey: .size)
    }

    /// Every release that can actually be downloaded, newest first. A v1 source
    /// lists none under `versions`, so the top-level release stands in for it.
    var releases: [AltVersion] {
        var out = (versions ?? []).filter { $0.url != nil }
        if out.isEmpty, let url = URL(string: downloadURL ?? ""),
           url.scheme == "https" || url.scheme == "http" {
            out = [AltVersion(version: version, buildVersion: nil, date: nil,
                              localizedDescription: localizedDescription,
                              downloadURL: downloadURL, size: size, minOSVersion: nil)]
        }
        return out.reversed()
    }

    var latest: AltVersion? { releases.first }

    var icon: URL? { URL(string: iconURL ?? "") }

    /// The screenshots as URLs, skipping anything that isn't one.
    var screenshotURLs: [URL] {
        (screenshots ?? []).compactMap { URL(string: $0) }
    }
}

/// One release of an app in a source.
struct AltVersion: Decodable, Identifiable, Equatable {

    let version: String?
    let buildVersion: String?
    let date: String?
    let localizedDescription: String?
    let downloadURL: String?
    let size: Int64?
    let minOSVersion: String?

    var id: String { (version ?? "?") + "|" + (buildVersion ?? "") + "|" + (downloadURL ?? "") }

    /// The download, when it's a link that can be followed.
    var url: URL? {
        guard let downloadURL, let url = URL(string: downloadURL),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    /// The release date as published (ISO 8601 for v2 sources).
    var dateValue: Date? {
        guard let date else { return nil }
        return ISO8601DateFormatter().date(from: date) ?? Self.dayFormatter.date(from: date)
    }

    var sizeText: String? {
        guard let size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// True when this release says it needs a newer iOS than the one running.
    var needsNewerOS: Bool {
        guard let major = Int((minOSVersion ?? "").split(separator: ".").first ?? "") else { return false }
        return major > ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// One news item in a source (v2), shown at the top of its page.
struct AltNews: Decodable, Identifiable {
    let title: String?
    let identifier: String?
    let caption: String?
    let date: String?
    let url: String?
    let appID: String?
    let tintColor: String?

    var id: String { identifier ?? title ?? UUID().uuidString }

    var link: URL? { URL(string: url ?? "") }
}

// MARK: - Loading and keeping sources

/// The sources the user added, fetched and cached. Sources are listed in the
/// order they were added; each keeps its last good copy on disk so the list
/// opens instantly and still works with no network.
@MainActor
final class SourceStore: ObservableObject {

    /// One source as the list shows it: its URL, and whatever came back.
    struct Loaded: Identifiable {
        let url: URL
        var source: AltSource?
        var error: String?
        var fetched: Date?
        var isLoading = false

        var id: String { url.absoluteString }
        var name: String { source?.name ?? url.host ?? url.absoluteString }
        var appCount: Int { source?.installableApps.count ?? 0 }
    }

    @Published private(set) var sources: [Loaded] = []
    /// Set while an add is downloading and decoding, so the field can show it.
    @Published private(set) var isAdding = false

    private static let defaultsKey = "altsource.urls"
    private let defaults = UserDefaults.standard
    /// One file per source, keyed by the URL's hash so any path is a safe name.
    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sources", isDirectory: true)
    }

    /// Sources offered before the user has added any: AltStore's own, which is
    /// the reference implementation of the format.
    static let starterSources = ["https://apps.altstore.io"]

    // MARK: Loading

    func load() {
        let saved = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        let links = saved.isEmpty ? Self.starterSources : saved
        guard sources.isEmpty else { return }
        sources = links.compactMap(URL.init(string:)).map { url in
            var loaded = Loaded(url: url)
            if let cached = Self.cachedSource(for: url) {
                loaded.source = cached.source
                loaded.fetched = cached.date
            }
            return loaded
        }
        Task { await refreshAll(force: false) }
    }

    /// Fetches every source. `force` re-downloads one that already loaded.
    func refreshAll(force: Bool = true) async {
        for loaded in sources where force || loaded.source == nil {
            await refresh(loaded.id)
        }
    }

    func refresh(_ id: String) async {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isLoading = true
        defer { if let still = sources.firstIndex(where: { $0.id == id }) { sources[still].isLoading = false } }
        do {
            let fetched = try await Self.fetch(sources[index].url)
            guard let still = sources.firstIndex(where: { $0.id == id }) else { return }
            sources[still].source = fetched.source
            sources[still].error = nil
            sources[still].fetched = Date()
            Self.cache(fetched.raw, for: sources[still].url)
        } catch {
            guard let still = sources.firstIndex(where: { $0.id == id }) else { return }
            sources[still].error = Self.message(for: error)
        }
    }

    // MARK: Adding and removing

    /// Adds the source at `text` (a pasted link, or an `altstore://source?url=`
    /// link someone shared). Returns nil on success, or why it couldn't be
    /// added.
    @discardableResult
    func add(_ text: String) async -> String? {
        guard !isAdding else { return nil }
        guard let url = Self.sourceURL(from: text) else {
            return L("That isn't a link to a source. Paste the whole https:// address of the source's JSON file.")
        }
        if sources.contains(where: { $0.url.absoluteString == url.absoluteString }) {
            return L("%@ is already in the list.", url.host ?? url.absoluteString)
        }
        isAdding = true
        defer { isAdding = false }
        do {
            let fetched = try await Self.fetch(url)
            var loaded = Loaded(url: url)
            loaded.source = fetched.source
            loaded.fetched = Date()
            sources.append(loaded)
            Self.cache(fetched.raw, for: url)
            saveURLs()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    func remove(_ id: String) {
        sources.removeAll { $0.id == id }
        saveURLs()
    }

    private func saveURLs() {
        defaults.set(sources.map { $0.url.absoluteString }, forKey: Self.defaultsKey)
    }

    // MARK: Links

    /// Turns pasted text into a source URL: adds `https://` when there's no
    /// scheme, and accepts an `altstore://source?url=` link as-is.
    nonisolated static func sourceURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URLComponents(string: trimmed),
           ["altstore", "sidestore", "sideinstaller"].contains(url.scheme?.lowercased() ?? ""),
           let inner = url.queryItems?.first(where: { $0.name.lowercased() == "url" })?.value {
            trimmed = inner
        }
        let lowered = trimmed.lowercased()
        let hadScheme = lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
        if !hadScheme {
            guard !trimmed.contains("://") else { return nil }
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    // MARK: Fetching

    /// Downloads and decodes one source, following redirects (a source is
    /// often a `github.io` page or a raw file). The raw bytes come back too, so
    /// the copy kept on disk is exactly what the server said — the models only
    /// decode, and re-encoding them would drop the fields they ignore.
    static func fetch(_ url: URL) async throws -> (source: AltSource, raw: Data) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SourceError.status(http.statusCode)
        }
        guard data.count < 24 << 20 else { throw SourceError.tooLarge }
        guard let source = decode(data) else { throw SourceError.notASource }
        guard !source.apps.isEmpty else { throw SourceError.noApps }
        var linked = source
        linked.sourceURL = url
        return (linked, data)
    }

    /// One source's worth of JSON, however it arrived.
    nonisolated static func decode(_ data: Data) -> AltSource? {
        try? JSONDecoder().decode(AltSource.self, from: data)
    }

    enum SourceError: LocalizedError {
        case status(Int)
        case tooLarge
        case noApps
        case notASource

        var errorDescription: String? {
            switch self {
            case .status(let code):
                return L("The server answered %ld. The link may have moved.", code)
            case .tooLarge:
                return L("That file is too big to be a source.")
            case .noApps:
                return L("That source lists no apps.")
            case .notASource:
                return L("That isn't an AltStore source. It has to be the source's JSON file, not a page that links to it.")
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? SourceError {
            return error.errorDescription ?? L("Couldn't load that source.")
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return L("Couldn't reach that source: %@", error.localizedDescription)
        }
        return L("Couldn't load that source: %@", error.localizedDescription)
    }

    // MARK: Cache

    nonisolated private static func cacheFile(for url: URL) -> URL {
        // A hash keeps any URL (paths, queries, a very long one) inside one
        // filename.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325      // FNV-1a
        for byte in Data(url.absoluteString.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return cacheDirectory.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    private static func cache(_ raw: Data, for url: URL) {
        guard let data = try? JSONEncoder().encode(CachedSource(raw: raw, date: Date())) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile(for: url), options: .atomic)
    }

    private static func cachedSource(for url: URL) -> (source: AltSource, date: Date)? {
        guard let data = try? Data(contentsOf: cacheFile(for: url)),
              let cached = try? JSONDecoder().decode(CachedSource.self, from: data),
              let source = decode(cached.raw)
        else { return nil }
        return (source, cached.date)
    }

    /// What's kept on disk: the source's JSON and when it was fetched.
    private struct CachedSource: Codable {
        let raw: Data
        let date: Date
    }
}
