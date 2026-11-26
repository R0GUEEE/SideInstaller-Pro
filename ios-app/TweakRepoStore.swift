import CryptoKit
import Foundation

/// The repositories the tweak browser reads, their cached indexes, and the
/// downloads it makes.
///
/// An index is kept on disk after it's read, so the browser opens with content
/// — and says when a refresh fails — the way the marketplace does with its
/// sources. The class stays non-isolated so `shared` can be read from a
/// property initializer; everything that touches published state is main-actor
/// bound, the way `SourceStore` is.
final class TweakRepoStore: ObservableObject {

    static let shared = TweakRepoStore()

    /// The repositories the user added, newest last.
    @Published private(set) var repos: [TweakRepository] = []
    /// Every package each repository lists, by repository.
    @Published private(set) var packages: [UUID: [RepoPackage]] = [:]
    /// Why the last read of a repository failed, so its row can say so.
    @Published private(set) var errors: [UUID: String] = [:]
    /// Repositories a read is running for.
    @Published private(set) var busy: Set<UUID> = []

    private static let file = "repos.json"
    private static let seededKey = "tweakRepos.seeded.v1"

    /// Two repositories with an open index, so the page has something to show
    /// before anything is added. Both publish a plain `Packages` file.
    private static let seeds = [
        ("https://havoc.app", "Havoc"),
        ("https://repo.chariz.com", "Chariz"),
    ]

    private init() {
        repos = Self.load()
        if repos.isEmpty, !UserDefaults.standard.bool(forKey: Self.seededKey) {
            repos = Self.seeds.map { TweakRepository(url: $0.0, name: $0.1) }
            UserDefaults.standard.set(true, forKey: Self.seededKey)
            save()
        }
        restoreCaches()
    }

    // MARK: - Adding and removing

    @MainActor
    @discardableResult
    func addRepo(_ raw: String) async throws -> TweakRepository {
        guard let normalized = Self.normalize(raw) else { throw RepoError.badURL(raw) }
        if repos.contains(where: { $0.url.caseInsensitiveCompare(normalized) == .orderedSame }) {
            throw RepoError.duplicate(normalized)
        }
        let host = URL(string: normalized)?.host ?? normalized
        let repo = TweakRepository(url: normalized, name: host)
        repos.append(repo)
        save()
        await refresh(repo)
        return self.repo(repo.id) ?? repo
    }

    @MainActor
    func remove(_ id: UUID) {
        repos.removeAll { $0.id == id }
        packages[id] = nil
        errors[id] = nil
        busy.remove(id)
        try? FileManager.default.removeItem(at: Self.cacheFile(id))
        save()
    }

    @MainActor
    func repo(_ id: UUID) -> TweakRepository? {
        repos.first { $0.id == id }
    }

    // MARK: - Reading

    /// Reads one repository's index, replacing what its row shows. A failure
    /// keeps the packages already cached and records why.
    @MainActor
    func refresh(_ repo: TweakRepository) async {
        guard !busy.contains(repo.id) else { return }
        busy.insert(repo.id)
        errors[repo.id] = nil
        defer { busy.remove(repo.id) }

        do {
            guard let base = URL(string: repo.url) else { throw RepoError.badURL(repo.url) }
            // A Release file names the repository; not having one isn't fatal.
            let release = try? await Self.text(base.appendingPathComponent("Release"))
            let raw = try await Self.fetchIndex(base: base)
            let id = repo.id
            let list = await Task.detached(priority: .userInitiated) {
                TweakRepoParser.packages(in: raw, repoID: id)
            }.value
            guard !list.isEmpty else { throw RepoError.empty }

            packages[id] = list
            if let index = repos.firstIndex(where: { $0.id == id }) {
                repos[index].updated = Date()
                repos[index].count = list.count
                if let label = release.flatMap(TweakRepoParser.label(in:)) {
                    repos[index].name = label
                }
            }
            let cache = Self.cacheFile(id)
            Task.detached(priority: .utility) {
                try? raw.write(to: cache, atomically: true, encoding: .utf8)
            }
            save()
        } catch {
            errors[repo.id] = error.localizedDescription
        }
    }

    /// Reads every repository, one at a time: a refresh is background work and
    /// has no reason to open several connections at once.
    @MainActor
    func refreshAll() async {
        for repo in repos { await refresh(repo) }
    }

    /// Reads the repositories that have never been read, which is what the
    /// first visit to the page needs. Later visits use the cached index.
    @MainActor
    func refreshIfStale() async {
        for repo in repos where repo.updated == nil {
            await refresh(repo)
        }
    }

    // MARK: - Updates

    /// The release a configured tweak could move to, when a repository here
    /// carries a newer version of it.
    ///
    /// Only packages whose identifier was recorded are considered: a bare
    /// `.dylib` has no version to compare, and a tweak added before identifiers
    /// were kept has none either, so it is left alone rather than nagged about.
    @MainActor
    func update(for tweak: Tweak) -> RepoPackage? {
        guard tweak.isDeb,
              let identifier = tweak.identifier, !identifier.isEmpty,
              let current = tweak.version, !current.isEmpty
        else { return nil }

        func newest(in repo: TweakRepository) -> RepoPackage? {
            packages[repo.id]?.first { $0.identifier == identifier }
        }

        // The repository it came from first; then, if that one no longer has
        // it, any repository that does.
        let preferred = tweak.repository.flatMap { origin in
            repos.first { $0.url.caseInsensitiveCompare(origin) == .orderedSame }
        }
        var ordered = repos.filter { $0.id != preferred?.id }
        if let preferred { ordered.insert(preferred, at: 0) }
        return ordered.compactMap(newest(in:))
            .first { TweakRepoParser.isNewer($0.version, than: current) }
    }

    // MARK: - Downloading

    /// Downloads a package's `.deb` to a temporary file and checks it against
    /// the index's SHA-256 when one is given.
    @MainActor
    func file(for package: RepoPackage) async throws -> URL {
        let base = repo(package.repoID)?.url ?? ""
        guard let url = Self.packageURL(filename: package.filename, base: base) else {
            throw RepoError.badURL(package.filename)
        }
        let data = try await Self.download(url, limit: 160 << 20)
        if let expected = package.sha256, !expected.isEmpty {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expected.lowercased() else { throw RepoError.checksum }
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.safeFileName(package.fileName, fallback: package.identifier))
        try data.write(to: destination, options: .atomic)
        return destination
    }

    // MARK: - URLs

    /// The base directory a repository URL stands for: a scheme is added when
    /// it's missing, a pasted `/Packages` is dropped, and a trailing slash goes.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        var path = components.path
        for suffix in ["/Packages.gz", "/Packages.xz", "/Packages.bz2", "/Packages.zst",
                       "/Packages.lzma", "/Packages"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        components.path = path == "/" ? "" : path
        components.query = nil
        components.fragment = nil
        return components.string
    }

    /// A `Filename` from the index, resolved against the repository's base.
    static func packageURL(filename: String, base: String) -> URL? {
        if filename.lowercased().hasPrefix("http://") || filename.lowercased().hasPrefix("https://") {
            return URL(string: filename)
        }
        var baseText = base
        if !baseText.hasSuffix("/") { baseText += "/" }
        guard let baseURL = URL(string: baseText) else { return nil }
        let relative = filename.hasPrefix("/") ? String(filename.dropFirst()) : filename
        return URL(string: relative, relativeTo: baseURL)?.absoluteURL
    }

    private static func safeFileName(_ name: String, fallback: String) -> String {
        let last = (name as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+"))
        let cleaned = String(last.unicodeScalars.filter { allowed.contains($0) })
        guard !cleaned.isEmpty else { return "\(fallback).deb" }
        return cleaned.lowercased().hasSuffix(".deb") ? cleaned : cleaned + ".deb"
    }

    // MARK: - Cache

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TweakRepos", isDirectory: true)
    }

    private static func cacheFile(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).Packages")
    }

    private static func load() -> [TweakRepository] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
              let list = try? JSONDecoder().decode([TweakRepository].self, from: data)
        else { return [] }
        return list
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(repos)
            try data.write(to: Self.directory.appendingPathComponent(Self.file), options: .atomic)
        } catch {
            // The list is a convenience, not the app's record: a write that
            // fails only means the next launch reads the seeds again.
        }
    }

    /// Parses the indexes kept from the last launch, off the main actor, so a
    /// million-line `Packages` doesn't hold up the first frame.
    private func restoreCaches() {
        let cached: [(UUID, String)] = repos.compactMap { repo in
            guard let text = try? String(contentsOf: Self.cacheFile(repo.id), encoding: .utf8)
            else { return nil }
            return (repo.id, text)
        }
        guard !cached.isEmpty else { return }
        Task.detached(priority: .utility) {
            let parsed = cached.map { (id, text) in
                (id, TweakRepoParser.packages(in: text, repoID: id))
            }
            await MainActor.run {
                for (id, list) in parsed where !list.isEmpty && self.packages[id] == nil {
                    self.packages[id] = list
                }
            }
        }
    }

    // MARK: - Networking

    private static func fetchIndex(base: URL) async throws -> String {
        var lastError: Error = RepoError.empty
        // The plain index first; a repository that only keeps the compressed
        // one is read through gzip, which DebArchive already knows how to undo.
        for name in ["Packages", "Packages.gz"] {
            do {
                let data = try await download(base.appendingPathComponent(name), limit: 32 << 20)
                if name.hasSuffix(".gz") {
                    let raw = try DebArchive.gunzip(data, limit: 96 << 20)
                    return String(decoding: raw, as: UTF8.self)
                }
                return String(decoding: data, as: UTF8.self)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func text(_ url: URL) async throws -> String {
        let data = try await download(url, limit: 64 << 10)
        return String(decoding: data, as: UTF8.self)
    }

    private static func download(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("SideInstaller", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw RepoError.http(http.statusCode)
            }
            guard data.count <= limit else { throw RepoError.tooLarge }
            return data
        } catch let error as RepoError {
            throw error
        } catch {
            throw RepoError.unreachable(error.localizedDescription)
        }
    }
}

/// What can go wrong reading a repository or taking a package out of it.
enum RepoError: LocalizedError {
    case badURL(String)
    case duplicate(String)
    case unreachable(String)
    case http(Int)
    case empty
    case tooLarge
    case checksum

    var errorDescription: String? {
        switch self {
        case .badURL(let text):
            return L("“%@” isn't a repository address. Paste the link you'd give Sileo, like https://repo.chariz.com.", text)
        case .duplicate(_):
            return L("That repository is already in the list.")
        case .unreachable(let reason):
            return L("Couldn't reach the repository: %@", reason)
        case .http(let code):
            return code == 404
                ? L("The repository has no Packages index.")
                : L("The repository answered with HTTP %d.", code)
        case .empty:
            return L("The index was read, but it lists no iOS packages.")
        case .tooLarge:
            return L("The file is larger than SideInstaller will download.")
        case .checksum:
            return L("The download doesn't match the checksum the repository published, so it was discarded.")
        }
    }
}

/// Downloads a package and hands the `.deb` to the configuration, which is the
/// only place that decides what a package contributes.
enum TweakPackageInstaller {

    /// Adds the package's library to the configuration, replacing the build of
    /// the same package that's already there. Returns false when the download
    /// was fine but there was nothing injectable in it.
    @discardableResult
    @MainActor
    static func add(_ package: RepoPackage, to store: AppConfigStore) async throws -> Bool {
        let repository = TweakRepoStore.shared.repo(package.repoID)?.url
        let file = try await TweakRepoStore.shared.file(for: package)
        defer { try? FileManager.default.removeItem(at: file) }
        return store.addTweaks([file], repository: repository).added == 1
    }
}

extension AppConfigStore {
    /// The copy of a repository package that's in the configuration: by package
    /// identifier when both sides have one, otherwise by the `.deb`'s name, so
    /// a tweak added before identifiers were kept is still recognised.
    func installedTweak(for package: RepoPackage) -> Tweak? {
        config.tweaks.first { $0.matches(fileName: package.fileName, identifier: package.identifier) }
    }
}
