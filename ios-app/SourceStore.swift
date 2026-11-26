import Combine
import Foundation

/// The sources the user added, and the apps they carry.
///
/// A source is fetched once, parsed into `MarketEntry` rows, and the *rows* are
/// what's cached — not the document. Opening the app then reads a few small
/// index files instead of re-downloading and re-parsing megabytes of JSON,
/// which is what made the marketplace slow on a big repository. A refresh is
/// conditional (`If-None-Match`), and only happens on its own when an index is
/// ancient or missing.
final class SourceStore: ObservableObject {

    /// The one instance: the marketplace, the app manager's update lookup and
    /// the diagnostics report all read the same list.
    static let shared = SourceStore()

    /// One source as the list shows it.
    struct Loaded: Identifiable {
        let url: URL
        var name = ""
        var icon: URL?
        var appCount = 0
        /// The shape its JSON turned out to be, for the row's label.
        var format: String = ""
        var error: String?
        var fetched: Date?
        var isLoading = false
        /// The apps this source marks as featured.
        var featured: Set<String> = []
        /// What it was recognised as when it was added.
        var origin = SourceOrigin(kind: .altSource, store: SourceKind.Store.other.rawValue)

        /// The Telegram channel to open when its posts can't be read.
        var telegramChannel: String? {
            origin.kind == .telegram ? TelegramSource.channel(from: url) : nil
        }

        var id: String { url.absoluteString }
        var hasIndex: Bool { appCount > 0 || fetched != nil }
    }

    @Published private(set) var sources: [Loaded] = []
    /// Every app from every source, one entry per bundle ID with all of its
    /// releases merged. This is what the marketplace draws.
    @Published private(set) var entries: [MarketEntry] = []
    @Published private(set) var revision = 0
    @Published private(set) var featuredKeys: Set<String> = []
    @Published private(set) var isAdding = false

    private static let defaultsKey = "altsource.urls"
    private let defaults = UserDefaults.standard
    private var indexBySource: [String: [MarketEntry]] = [:]

    /// How long a cached index is trusted. A source that updates hourly isn't
    /// worth a fetch every launch; pull-to-refresh and Refresh all force one.
    private static let indexLifetime: TimeInterval = 6 * 60 * 60

    static let starterSources = ["https://apps.altstore.io"]

    // MARK: - Loading

    @MainActor
    func load() {
        guard sources.isEmpty else { return }
        let saved = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        let links = saved.isEmpty ? Self.starterSources : saved
        sources = links.compactMap(URL.init(string:)).map { Loaded(url: $0) }
        Task {
            // Cached rows first: no network, no parsing.
            let links = sources.map { $0.url }
            let loaded = await Task.detached(priority: .userInitiated) { () -> [(String, SourceIndex?)] in
                links.map { ($0.absoluteString, SourceStore.cachedIndex(for: $0)) }
            }.value
            for (id, index) in loaded {
                guard let index, let at = sources.firstIndex(where: { $0.id == id }) else { continue }
                adopt(index, at: at)
            }
            merge()
            await refreshAll(force: false)
        }
    }

    @MainActor
    private func adopt(_ index: SourceIndex, at position: Int) {
        sources[position].name = index.name
        sources[position].icon = URL(string: index.icon ?? "")
        sources[position].format = index.format
        sources[position].fetched = index.date
        sources[position].featured = Set(index.featured)
        indexBySource[sources[position].id] = index.entries
        sources[position].appCount = index.entries.count
    }

    /// Fetches the sources that need it: missing, or older than the lifetime.
    @MainActor
    func refreshAll(force: Bool = true) async {
        let wanted = sources.filter { source in
            guard !source.isLoading else { return false }
            if force { return true }
            guard let date = source.fetched else { return true }
            return Date().timeIntervalSince(date) > Self.indexLifetime
        }.map(\.id)
        guard !wanted.isEmpty else { return }
        // Four at a time: sources are independent hosts and most of the wait is
        // the network, not the decoding.
        await withTaskGroup(of: Void.self) { group in
            var pending = wanted[...]
            func addNext() {
                guard let id = pending.popFirst() else { return }
                group.addTask { await self.refresh(id, force: force) }
            }
            for _ in 0..<4 { addNext() }
            for await _ in group { addNext() }
        }
        merge()
    }

    @MainActor
    func refresh(_ id: String, force: Bool = true) async {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isLoading = true
        let url = sources[index].url
        let origin = sources[index].origin
        defer { if let still = sources.firstIndex(where: { $0.id == id }) { sources[still].isLoading = false } }

        do {
            if origin.kind == .github, let parts = GitHubSource.repo(from: url) {
                let name = sources[index].name.isEmpty ? "\(parts.owner)/\(parts.repo)" : sources[index].name
                let entries = try await GitHubSource.entries(owner: parts.owner, repo: parts.repo,
                                                            sourceName: name)
                store(SourceIndex(name: name, icon: "https://github.com/\(parts.owner).png?size=120",
                                  format: "GitHub", date: Date(), etag: nil, featured: [],
                                  entries: entries), for: id)
            } else if origin.kind == .telegram {
                guard let channel = TelegramSource.channel(from: url) else {
                    throw SourceError.notASource
                }
                let read = try await TelegramSource.entries(channel: channel)
                store(SourceIndex(name: read.name, icon: nil, format: "Telegram",
                                  date: Date(), etag: nil, featured: [],
                                  entries: read.entries), for: id)
            } else {
                let cached = Self.cachedIndex(for: url)
                // A deliberate refresh asks for the body: only the automatic
                // pass revalidates with the ETag.
                let raw = try await Self.fetchDocument(url, etag: force ? nil : cached?.etag)
                switch raw {
                case .unchanged:
                    // Nothing changed: keep the rows, move the clock so the
                    // lifetime restarts.
                    if var kept = cached {
                        kept.date = Date()
                        save(kept, for: url)
                        if let at = sources.firstIndex(where: { $0.id == id }) {
                            sources[at].fetched = kept.date
                        }
                    }
                case .document(let data, let etag):
                    let parsed = await Task.detached(priority: .userInitiated) { () -> SourceParser.Parsed? in
                        SourceParser.parse(data, sourceName: url.host ?? "Source",
                                           sourceID: url.absoluteString)
                    }.value
                    guard let parsed else { throw SourceError.notASource }
                    store(SourceIndex(name: parsed.name ?? url.host ?? "Source",
                                      icon: parsed.icon,
                                      format: SourceParser.format(of: data).rawValue,
                                      date: Date(), etag: etag, featured: parsed.featured,
                                      entries: parsed.entries), for: id)
                }
            }
        } catch {
            if let at = sources.firstIndex(where: { $0.id == id }) {
                sources[at].error = Self.message(for: error)
            }
        }
    }

    /// Puts a fresh index in place for one source.
    @MainActor
    private func store(_ index: SourceIndex, for id: String) {
        guard let at = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[at].name = index.name
        sources[at].icon = URL(string: index.icon ?? "")
        sources[at].format = index.format
        sources[at].error = nil
        sources[at].fetched = index.date
        sources[at].featured = Set(index.featured)
        sources[at].appCount = index.entries.count
        indexBySource[id] = index.entries
        save(index, for: sources[at].url)
    }

    /// Merges every source's rows into one list: one entry per bundle ID, its
    /// releases from all of them, each tagged with the source that carries it.
    @MainActor
    private func merge() {
        var merged: [String: MarketEntry] = [:]
        var capacity = 0
        for entries in indexBySource.values { capacity += entries.count }
        merged.reserveCapacity(capacity)

        for id in sources.map(\.id) {
            guard let entries = indexBySource[id] else { continue }
            for entry in entries {
                guard var existing = merged[entry.id] else {
                    merged[entry.id] = entry
                    continue
                }
                var seen = Set(existing.versions.map(\.id))
                for version in entry.versions where seen.insert(version.id).inserted {
                    existing.versions.append(version)
                }
                existing.versions.sort { lhs, rhs in
                    let left = lhs.date ?? .distantPast
                    let right = rhs.date ?? .distantPast
                    if left != right { return left > right }
                    return (lhs.version ?? "").compare(rhs.version ?? "", options: .numeric) == .orderedDescending
                }
                if (entry.latest?.date ?? .distantPast) > (existing.latest?.date ?? .distantPast) {
                    existing.name = entry.name
                    existing.developer = entry.developer ?? existing.developer
                    existing.subtitle = entry.subtitle ?? existing.subtitle
                    existing.icon = entry.icon ?? existing.icon
                }
                merged[entry.id] = existing
            }
        }
        entries = merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        featuredKeys = sources.reduce(into: Set<String>()) { $0.formUnion($1.featured) }
        revision += 1
    }

    /// How many apps a source contributes.
    @MainActor
    func count(for id: String) -> Int {
        indexBySource[id]?.count ?? 0
    }

    // MARK: - Adding and removing

    @discardableResult
    @MainActor
    func add(_ text: String, origin: SourceOrigin? = nil) async -> String? {
        guard !isAdding else { return nil }
        guard let url = Self.sourceURL(from: text) else {
            return L("That isn't a link to a source. Paste the whole https:// address of the source's JSON file.")
        }
        let detected = origin ?? SourceOrigin.detect(text)
        if sources.contains(where: { $0.url.absoluteString == url.absoluteString }) {
            return L("%@ is already in the list.", url.host ?? url.absoluteString)
        }
        isAdding = true
        defer { isAdding = false }
        var loaded = Loaded(url: url)
        loaded.origin = detected
        do {
            switch detected.kind {
            case .github:
                guard let parts = GitHubSource.repo(from: url) else {
                    return L("That isn't a GitHub repository link. It should look like github.com/owner/repo.")
                }
                loaded.name = "\(parts.owner)/\(parts.repo)"
                let entries = try await GitHubSource.entries(owner: parts.owner, repo: parts.repo,
                                                            sourceName: loaded.name)
                let index = SourceIndex(name: loaded.name,
                                        icon: "https://github.com/\(parts.owner).png?size=120",
                                        format: "GitHub", date: Date(), etag: nil, featured: [],
                                        entries: entries)
                sources.append(loaded)
                store(index, for: loaded.id)
            case .telegram:
                guard let channel = TelegramSource.channel(from: url) else {
                    return L("That isn't a Telegram channel link. It should look like t.me/channel.")
                }
                let read = try await TelegramSource.entries(channel: channel)
                let index = SourceIndex(name: read.name, icon: nil, format: "Telegram",
                                        date: Date(), etag: nil, featured: [],
                                        entries: read.entries)
                sources.append(loaded)
                store(index, for: loaded.id)
            case .altSource:
                let document = try await Self.fetchDocument(url, etag: nil)
                guard case .document(let data, let etag) = document else { return nil }
                let parsed = await Task.detached(priority: .userInitiated) { () -> SourceParser.Parsed? in
                    SourceParser.parse(data, sourceName: url.host ?? "Source",
                                       sourceID: url.absoluteString)
                }.value
                guard let parsed else { throw SourceError.notASource }
                let index = SourceIndex(name: parsed.name ?? url.host ?? "Source",
                                        icon: parsed.icon,
                                        format: SourceParser.format(of: data).rawValue,
                                        date: Date(), etag: etag, featured: parsed.featured,
                                        entries: parsed.entries)
                sources.append(loaded)
                store(index, for: loaded.id)
            }
            saveURLs()
            merge()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    @MainActor
    func remove(_ id: String) {
        if let entry = sources.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: Self.indexFile(for: entry.url))
        }
        sources.removeAll { $0.id == id }
        indexBySource[id] = nil
        saveURLs()
        merge()
    }

    @MainActor
    private func saveURLs() {
        defaults.set(sources.map { $0.url.absoluteString }, forKey: Self.defaultsKey)
    }

    // MARK: Links

    nonisolated static func sourceURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URLComponents(string: trimmed),
           ["altstore", "sidestore", "sideinstaller", "esign", "esignplus", "feather",
            "scarlet", "flarestore", "gbox"].contains(url.scheme?.lowercased() ?? ""),
           let inner = url.queryItems?.first(where: { $0.name.lowercased() == "url" })?.value {
            trimmed = inner
        }
        let lowered = trimmed.lowercased()
        // A local file is a source too: that's what the Telegram studio writes,
        // and it lets a generated list be browsed like any other.
        if lowered.hasPrefix("file://"), let url = URL(string: trimmed) {
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let hadScheme = lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
        if !hadScheme {
            guard !trimmed.contains("://") else { return nil }
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    // MARK: Fetching

    enum Document {
        /// The server says the cached copy is current.
        case unchanged
        case document(Data, etag: String?)
    }

    /// A conditional GET: the cached `ETag` goes back as `If-None-Match`, and
    /// most source hosts answer 304 with no body at all.
    nonisolated static func fetchDocument(_ url: URL, etag: String?) async throws -> Document {
        // A `file://` source is read from disk; there's nothing conditional
        // about it, and it changes whenever the app regenerates it.
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                throw SourceError.notASource
            }
            return .document(data, etag: nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SideInstaller", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 304, etag != nil { return .unchanged }
            guard (200...299).contains(http.statusCode) else {
                throw SourceError.status(http.statusCode)
            }
        }
        guard data.count < 48 << 20 else { throw SourceError.tooLarge }
        guard !data.isEmpty else { throw SourceError.notASource }
        return .document(data, etag: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
    }

    enum SourceError: LocalizedError {
        case status(Int)
        case tooLarge
        case notASource

        var errorDescription: String? {
            switch self {
            case .status(let code):
                return L("The server answered %ld. The link may have moved.", code)
            case .tooLarge:
                return L("That file is too big to be a source.")
            case .notASource:
                return L("That link didn't return a repository. It has to be the source's JSON file — AltStore, SideStore, Scarlet, GBox, E-Sign or Feather format — not a page that links to it.")
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

    // MARK: Index cache

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SourceIndex", isDirectory: true)
    }

    nonisolated private static func indexFile(for url: URL) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325      // FNV-1a
        for byte in Data(url.absoluteString.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return cacheDirectory.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    nonisolated private static func cachedIndex(for url: URL) -> SourceIndex? {
        guard let data = try? Data(contentsOf: indexFile(for: url)) else { return nil }
        return try? JSONDecoder().decode(SourceIndex.self, from: data)
    }

    nonisolated private static func save(_ index: SourceIndex, for url: URL) {
        // Writes happen off the caller's thread; the file is small and atomic.
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: indexFile(for: url), options: .atomic)
    }

    @MainActor
    private func save(_ index: SourceIndex, for url: URL) {
        Self.save(index, for: url)
    }
}

/// One source's parsed rows, as kept on disk.
///
/// This is the cache that makes opening the app cheap: reading it costs a small
/// JSON decode, where re-scanning a ten-megabyte repository costs seconds.
struct SourceIndex: Codable {
    var version = 1
    var name: String
    var icon: String?
    var format: String
    var date: Date
    var etag: String?
    var featured: [String]
    var entries: [MarketEntry]
}
