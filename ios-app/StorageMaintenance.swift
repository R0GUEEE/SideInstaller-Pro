import Foundation

/// Only app-owned disposable data is eligible. Credentials, pairing records,
/// user downloads and the latest re-signing IPAs are never swept here.
enum StorageMaintenance {
    @MainActor static func atLaunch() {
        // Queue state is in memory, so no previous process can still need its staging.
        BulkInstallStage.prune(keeping: [])
        InstallHistory.shared.trimStorage()
        cleanStaleTemporaryFiles(in: FileManager.default.temporaryDirectory)
        cleanCacheDebris(in: IPACache.directory)
    }

    /// Startup-only recovery for crashed/failed imports and signing operations.
    /// Fresh temporary files and names owned by other features are left alone.
    static func cleanStaleTemporaryFiles(in directory: URL, now: Date = Date(),
                                         maxAge: TimeInterval = 86_400) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: directory,
                          includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let name = url.lastPathComponent
            let owned = name.hasPrefix("ipa-link-") || name.hasPrefix("ipa-import-")
                || (name.hasPrefix("patch-") && name.hasSuffix(".ipa"))
                || name.hasSuffix("_extracted")
            guard owned,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate,
                  now.timeIntervalSince(date) > maxAge else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// At startup there are no cache writes in flight. Remove interrupted copies
    /// and orphan name sidecars, but retain every completed IPA.
    static func cleanCacheDebris(in directory: URL) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: directory,
                                               includingPropertiesForKeys: nil)) ?? [] {
            if url.lastPathComponent.hasSuffix(".ipa.incoming")
                || (url.lastPathComponent.hasSuffix(".ipa.name")
                    && !fm.fileExists(atPath: url.deletingPathExtension().path)) {
                try? fm.removeItem(at: url)
            }
        }
    }
}
