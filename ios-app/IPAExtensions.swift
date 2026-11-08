import Foundation

/// The extension bundles inside an IPA, read from its archive.
///
/// Reading them up front is what lets the install menu say, before a run, that
/// an app ships plugins and whether each one's identifier sits under the app's —
/// the condition iOS enforces, and the one the signer refuses on.
enum IPAExtensions {

    static func read(_ ipa: URL) -> [Engine.BuildExtension] {
        guard let archive = IPALibrary.archiveFiles(at: ipa) else { return [] }
        return read(archive: archive, ipa: ipa)
    }

    /// An `.appex` under `Frameworks/` rather than the app's `PlugIns/`.
    ///
    /// The signer only looks for extensions in `PlugIns`, so one of these never
    /// gets an App ID, a profile or entitlements of its own; it is signed with
    /// an empty entitlement set and cannot register with the extension host.
    /// The signer now refuses such a build outright, and the install menu says
    /// so before anything is downloaded.
    struct StrayExtension {
        let path: String
        let bundleID: String
    }

    static func strays(in ipa: URL) -> [StrayExtension] {
        guard let archive = IPALibrary.archiveFiles(at: ipa) else { return [] }
        return strays(archive: archive, ipa: ipa)
    }

    static func strays(archive: [IPALibrary.ArchiveFile], ipa: URL) -> [StrayExtension] {
        guard let app = archive.first(where: {
            $0.path.hasSuffix("/Info.plist") && $0.path.contains("Payload/")
                && $0.path.split(separator: "/").count == 3
        }) else { return [] }
        let prefix = String(app.path.dropLast("Info.plist".count))

        var out: [StrayExtension] = []
        for file in archive where file.path.hasPrefix(prefix + "Frameworks/") && file.path.hasSuffix("/Info.plist") {
            let parts = file.path.split(separator: "/").map(String.init)
            guard let leaf = parts.dropLast().last, leaf.hasSuffix(".appex") else { continue }
            guard !parts.contains("PlugIns") else { continue }
            guard let data = IPALibrary.contents(of: file, in: ipa),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let bundleID = plist["CFBundleIdentifier"] as? String else { continue }
            out.append(StrayExtension(path: file.path, bundleID: bundleID))
        }
        return out.sorted { $0.path < $1.path }
    }

    static func read(archive: [IPALibrary.ArchiveFile], ipa: URL) -> [Engine.BuildExtension] {
        // The app's own identifier, so each extension can be compared with it.
        guard let appInfo = IPAPatch.readInfoPlist(from: ipa),
              let appID = appInfo["CFBundleIdentifier"] as? String,
              let app = archive.first(where: {
                  $0.path.hasSuffix("/Info.plist") && $0.path.contains("Payload/")
                      && $0.path.split(separator: "/").count == 3
              }) else { return [] }
        let prefix = String(app.path.dropLast("Info.plist".count))

        var out: [Engine.BuildExtension] = []
        for file in archive where file.path.hasPrefix(prefix) && file.path.hasSuffix("/Info.plist") {
            let parts = file.path.split(separator: "/").map(String.init)
            guard let leaf = parts.dropLast().last, leaf.hasSuffix(".appex") else { continue }
            guard let data = IPALibrary.contents(of: file, in: ipa),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let bundleID = plist["CFBundleIdentifier"] as? String else { continue }
            let path = String(file.path.dropLast("Info.plist".count))
            out.append(Engine.BuildExtension(
                path: path.replacingOccurrences(of: prefix, with: ""),
                bundleID: bundleID,
                isChild: bundleID.hasPrefix(appID + ".")))
        }
        return out.sorted { $0.path < $1.path }
    }
}
