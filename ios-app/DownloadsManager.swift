import Foundation
import Combine

/// One IPA in Documents, as the download manager in Settings lists it.
struct DownloadedIPA: Identifiable, Equatable {
    let source: InstallSource
    let channel: ReleaseChannel
    let url: URL
    let size: Int
    let modified: Date?
    /// True when this file arrived from the Files app rather than a download.
    let isImported: Bool
    /// The release picked under Advanced that this was downloaded as.
    let version: String?

    /// Stable identity: the path is unique per source and channel.
    var id: String { url.path }

    /// Channel-qualified name, e.g. "LiveContainer + SideStore (Nightly)" or
    /// "SideStore 0.6.3", or the filename for a custom IPA, which the row
    /// already names.
    var displayName: String {
        guard source != .custom else { return fileName }
        var name = source.displayName
        if let version { name += " \(version)" }
        if channel == .nightly { name += " (\(channel.displayName))" }
        if isImported { name += " — \(L("imported"))" }
        return name
    }

    /// The on-disk filename, e.g. "SideStore.ipa".
    var fileName: String { url.lastPathComponent }

    /// Human-readable size, e.g. "42.3 MB".
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// Lists and deletes the IPAs in Documents. Pure file-system work, so it runs
/// inline on the main thread.
final class DownloadsManager: ObservableObject {

    @Published private(set) var downloads: [DownloadedIPA] = []
    /// `id` of the IPA currently being deleted, if any.
    @Published private(set) var deletingID: String?
    @Published var lastError: String?
    /// True once `refresh()` has run (tells "not loaded" apart from "empty").
    @Published private(set) var hasLoaded = false

    private var engine: Engine { Engine.shared }

    /// Total bytes across every IPA, for the header summary.
    var totalSize: Int { downloads.reduce(0) { $0 + $1.size } }

    var totalSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
    }

    // MARK: - Actions

    /// Rebuild the list from disk, scanning the directory so hand-copied files
    /// appear too. Safe to call repeatedly.
    @MainActor
    func refresh() {
        downloads = IPALibrary.scan().map {
            DownloadedIPA(source: $0.source, channel: $0.channel, url: $0.url,
                          size: $0.size, modified: $0.modified, isImported: $0.isImported,
                          version: $0.version)
        }
        hasLoaded = true
    }

    /// Keeps only the newest `.ipa` of each app on disk, deleting older builds of
    /// the same bundle ID. Returns how many went and how much space came back.
    ///
    /// "Newest" is the newer version number, then the later file date; a file
    /// whose plist can't be read is never deleted, because there's no way to say
    /// which app it belongs to. The build the Install tab is pointed at survives
    /// even if another copy is newer — deleting the file under a run would be a
    /// surprise, not a cleanup.
    @MainActor
    @discardableResult
    static func keepNewestOnly() -> (removed: Int, freed: Int) {
        let fm = FileManager.default
        let protected = Set([Engine.shared.downloadedIPAPath,
                             IPALibrary.customImport()?.url.path].compactMap { $0 })

        // Everything installable, grouped by the app it carries.
        var groups: [String: [(url: URL, version: String?, date: Date, size: Int)]] = [:]
        for entry in IPALibrary.scan() {
            // The re-signing cache is owned by IPACache, not download cleanup.
            // A newer download is not evidence that it was successfully installed.
            guard entry.url.deletingLastPathComponent().standardizedFileURL != IPACache.directory.standardizedFileURL else { continue }
            guard let info = IPALibrary.appInfo(at: entry.url) else { continue }
            groups[info.bundleID, default: []].append(
                (entry.url, info.version, entry.modified ?? .distantPast, entry.size))
        }

        var removed = 0
        var freed = 0
        for (_, files) in groups where files.count > 1 {
            // The winner: highest version, later date as the tie-break.
            let sorted = files.sorted { lhs, rhs in
                switch (lhs.version, rhs.version) {
                case let (l?, r?) where l != r:
                    return l.compare(r, options: .numeric) == .orderedDescending
                default:
                    return lhs.date > rhs.date
                }
            }
            guard !sorted.isEmpty else { continue }
            for file in sorted.dropFirst() {
                guard !protected.contains(file.url.path) else { continue }
                // Never delete a cache entry the app depends on for re-signing
                // when it is the only copy left for that app.
                do {
                    try fm.removeItem(at: file.url)
                    DownloadLedger.forget(file.url)
                    removed += 1
                    freed += file.size
                    Engine.shared.log("Downloads: removed an older \(file.version ?? "build") (\(file.url.lastPathComponent)).")
                } catch {
                    Engine.shared.log("⚠️ Downloads: couldn't remove \(file.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return (removed, freed)
    }

    /// Delete one downloaded IPA, then refresh the list.
    @MainActor
    func delete(_ item: DownloadedIPA) {
        guard deletingID == nil else { return }
        deletingID = item.id
        lastError = nil
        do {
            try FileManager.default.removeItem(at: item.url)
            DownloadLedger.forget(item.url)
            // Drop the pipeline's cached path so it re-fetches this file.
            if engine.downloadedIPAPath == item.url.path {
                engine.downloadedIPAPath = nil
            }
            // Update the Install tab's custom IPA button.
            if item.source == .custom { engine.refreshCustomIPA() }
            engine.log("Downloads: deleted \(item.fileName) (\(item.sizeText)).")
        } catch {
            lastError = L("Couldn't delete %@: %@", item.fileName, error.localizedDescription)
            engine.log("⛔️ Downloads: \(lastError ?? "delete failed")")
        }
        deletingID = nil
        refresh()
    }
}

