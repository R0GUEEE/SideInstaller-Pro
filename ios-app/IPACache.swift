import Foundation

/// Keeps a copy of every `.ipa` SideInstaller installs, so the app can be
/// re-signed later.
///
/// Re-signing an app needs its original `.ipa`: the signed bundle on the device
/// can't be pulled back out (iOS doesn't expose another app's `.app`), and a file
/// the user picked may be gone by the time the profile expires. So a copy is kept
/// per bundle ID, under Application Support — inside the app's container, not
/// visible in Files, and never uploaded anywhere.
///
/// It's the difference between "Re-sign" working for everything SideInstaller
/// installed and "Re-sign" working only while the original download happens to
/// still be in Documents.
enum IPACache {

    /// One cached build.
    struct Cached: Identifiable {
        let bundleID: String
        let url: URL
        let bytes: Int64
        let savedAt: Date
        /// What the app was called when it was installed, for the list.
        let displayName: String

        var id: String { bundleID }
        var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }

    /// Where copies live. Application Support, not Documents: this is the app's
    /// own bookkeeping, not a place for the user to shuffle files.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("IPACache", isDirectory: true)
    }

    /// Keeps `ipa` as the copy for `bundleID`, replacing any previous one.
    ///
    /// The file is copied rather than moved: the caller may still need it (a
    /// download in Documents, the custom import, a refresh's source).
    @discardableResult
    static func store(_ ipa: URL, bundleID: String,
                      displayName: String) -> Cached? {
        guard !bundleID.isEmpty,
              FileManager.default.fileExists(atPath: ipa.path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = file(for: bundleID)
            let temporary = destination.appendingPathExtension("incoming")
            try? FileManager.default.removeItem(at: temporary)
            try FileManager.default.copyItem(at: ipa, to: temporary)
            // Replace atomically, so a crash mid-copy can't leave a half file
            // where a rescuable app used to be.
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            writeName(displayName, for: bundleID)
            Engine.shared.log("Cached \(destination.lastPathComponent) for re-signing.")
            return Cached(bundleID: bundleID, url: destination,
                          bytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                          savedAt: (attributes?[.modificationDate] as? Date) ?? Date(),
                          displayName: displayName)
        } catch {
            Engine.shared.log("⚠️ Couldn't cache this .ipa for re-signing: \(error.localizedDescription)")
            return nil
        }
    }

    /// The cached build for an app, if there is one.
    static func cached(for bundleID: String) -> Cached? {
        let url = file(for: bundleID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Cached(bundleID: bundleID, url: url,
                      bytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                      savedAt: (attributes?[.modificationDate] as? Date) ?? Date(),
                      displayName: name(for: bundleID) ?? bundleID)
    }

    /// Every cached build, newest first.
    static func all() -> [Cached] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".ipa") }
            .compactMap { cached(for: String($0.dropLast(4))) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    static func remove(_ bundleID: String) {
        try? FileManager.default.removeItem(at: file(for: bundleID))
        try? FileManager.default.removeItem(at: nameFile(for: bundleID))
    }

    /// Every cached build, read off the main actor: listing the folder and
    /// stat-ing each file is disk work a SwiftUI body must not do.
    static func load() async -> [Cached] {
        await Task.detached(priority: .userInitiated) { all() }.value
    }

    static func totalBytes() -> Int64 {
        all().reduce(0) { $0 + $1.bytes }
    }

    /// Drops copies older than `days`, or the largest ones when the folder is
    /// over `limit`, so the cache can't grow without bound.
    static func prune(olderThan days: Int = 60, keepingUnder limit: Int64 = 2 << 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for entry in all() where entry.savedAt < cutoff {
            remove(entry.bundleID)
        }
        var total = totalBytes()
        guard total > limit else { return }
        // Oldest first, until it fits.
        for entry in all().reversed() where total > limit {
            remove(entry.bundleID)
            total -= entry.bytes
        }
    }

    // MARK: - Files

    /// A file name from the bundle ID. The ID is already DNS-shaped, but it's
    /// escaped anyway so a stray slash can never escape the folder.
    private static func file(for bundleID: String) -> URL {
        let safe = bundleID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe + ".ipa")
    }

    private static func nameFile(for bundleID: String) -> URL {
        file(for: bundleID).appendingPathExtension("name")
    }

    private static func writeName(_ name: String, for bundleID: String) {
        try? Data(name.utf8).write(to: nameFile(for: bundleID), options: .atomic)
    }

    private static func name(for bundleID: String) -> String? {
        guard let data = try? Data(contentsOf: nameFile(for: bundleID)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

