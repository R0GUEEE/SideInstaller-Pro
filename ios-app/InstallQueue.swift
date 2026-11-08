import Combine
import Foundation

/// A line of installs, run one after another.
///
/// The pipeline signs and installs one app at a time — they share a device link,
/// one pairing file and Apple's rate limit — so a queue is the honest shape for
/// "do these five". Each item also remembers the newest release it was given, so
/// a failed one can be retried without hunting for the link again.
@MainActor
final class InstallQueue: ObservableObject {

    static let shared = InstallQueue()

    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case waiting
            case installing
            case done
            case failed(String)
        }

        let id = UUID()
        var name: String
        var url: URL
        /// The bundle ID, when it's known before the download.
        var bundleID: String?
        var state: State = .waiting

        var isFinished: Bool {
            switch state {
            case .done, .failed: return true
            case .waiting, .installing: return false
            }
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false

    private var runner: Task<Void, Never>?

    private let install: @MainActor (URL) async throws -> Void

    init(install: @escaping @MainActor (URL) async throws -> Void = {
        try await Engine.shared.installQueuedIPA($0)
    }) {
        self.install = install
    }

    var pending: [Item] { items.filter { !$0.isFinished } }

    /// Adds a build to the end of the line. Returns false when it's already in it.
    @discardableResult
    func add(name: String, url: URL, bundleID: String? = nil) -> Bool {
        guard !items.contains(where: { $0.url == url && !$0.isFinished }) else { return false }
        items.append(Item(name: name, url: url, bundleID: bundleID))
        return true
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        items.removeAll { $0.isFinished }
    }

    func clearAll() {
        guard !isRunning else { return }
        items.removeAll()
    }

    /// Starts the line. Does nothing when it's already running or empty.
    func start() {
        guard !isRunning, !pending.isEmpty else { return }
        isRunning = true
        runner = Task { [weak self] in
            await self?.run()
        }
    }

    func cancel() {
        runner?.cancel()
        for index in items.indices where items[index].state == .waiting {
            items[index].state = .failed(L("Cancelled"))
        }
        // Keep the queue busy until the engine has reached a safe stopping point.
    }

    private func run() async {
        defer { isRunning = false; runner = nil }
        while !Task.isCancelled, let next = items.first(where: { $0.state == .waiting }) {
            guard let index = items.firstIndex(where: { $0.id == next.id }) else { break }
            items[index].state = .installing
            let result: Item.State
            do {
                try Task.checkCancellation()
                try await install(next.url)
                try Task.checkCancellation()
                result = .done
            } catch is CancellationError {
                result = .failed(L("Cancelled"))
            } catch {
                result = .failed(error.localizedDescription)
            }
            if let index = items.firstIndex(where: { $0.id == next.id }) {
                items[index].state = result
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

}

/// What has been installed, and how to get back to it.
///
/// Every successful install records the build and the copy `IPACache` kept, so
/// "roll back to what I had" is a row in a list rather than a search for an old
/// download.
@MainActor
final class InstallHistory: ObservableObject {

    static let shared = InstallHistory()

    struct Entry: Identifiable, Codable {
        let id: UUID
        let bundleID: String
        let name: String
        let version: String?
        /// Where the copy is, relative to the app container. Stored so a change
        /// in container paths between launches doesn't break old records.
        let cachedPath: String?
        let date: Date
        /// Where it came from, for the row: a source's name, "imported", a queue…
        let origin: String?

        var cachedURL: URL? {
            guard let cachedPath else { return nil }
            // Legacy entries point at the mutable IPACache file. They cannot
            // identify an old build safely, so only immutable snapshots qualify.
            guard !cachedPath.contains("/"), cachedPath.hasSuffix(".ipa") else { return nil }
            let url = InstallHistoryArchive.directory.appendingPathComponent(cachedPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    @Published private(set) var entries: [Entry] = []

    private static let defaultsKey = "install.history.v1"
    private static let limit = 200

    private init() {
        entries = Self.load()
    }

    /// Records a successful install. Called by the engine once an install ends.
    func record(bundleID: String, name: String, version: String?,
                cached: URL?, origin: String?) {
        // Repeating the same build shouldn't stack up identical rows.
        if let last = entries.first, last.bundleID == bundleID,
           last.version == version,
           Date().timeIntervalSince(last.date) < 60 {
            return
        }
        let snapshot = cached.flatMap { try? InstallHistoryArchive.store($0) }
        let entry = Entry(id: UUID(), bundleID: bundleID, name: name, version: version,
                          cachedPath: snapshot?.lastPathComponent, date: Date(), origin: origin)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
        InstallHistoryArchive.prune(keeping: entries.compactMap(\.cachedPath))
    }

    /// The newest earlier build of `bundleID` that's still on disk — what a roll
    /// back would install.
    func previousBuild(of bundleID: String) -> Entry? {
        entries.filter { $0.bundleID == bundleID && $0.cachedURL != nil }
            .dropFirst()
            .first
    }

    func clear() {
        entries.removeAll()
        save()
        InstallHistoryArchive.prune(keeping: [])
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }
}


/// Where a bulk install's files are put so the queue can read them later.
///
/// A picker's URL is security-scoped and stops being readable the moment the
/// picker closes, so each file is copied out first. The copies are the queue's
/// own; clearing them is the queue's business too, once the item is done.
enum BulkInstallStage {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BulkInstall", isDirectory: true)
    }

    /// Copies one picked file in, returning where it landed.
    static func stage(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let batch = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let destination = batch.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: batch)
            throw error
        }
    }

    /// Deletes the copies for builds no longer in the queue.
    static func prune(keeping urls: [URL]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        let keep = Set(urls.filter { $0.isFileURL }.map { url in
            url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
                ? url.lastPathComponent : url.deletingLastPathComponent().lastPathComponent
        })
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}


/// Immutable copies: history never points at the mutable latest-build cache.
enum InstallHistoryArchive {
    static var directory: URL {
        IPACache.directory.deletingLastPathComponent()
            .appendingPathComponent("InstallHistory", isDirectory: true)
    }

    static func store(_ source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + ".ipa")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    static func prune(keeping names: [String]) {
        let keep = Set(names)
        for url in (try? FileManager.default.contentsOfDirectory(at: directory,
                                        includingPropertiesForKeys: nil)) ?? [] {
            if !keep.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        }
    }
}
