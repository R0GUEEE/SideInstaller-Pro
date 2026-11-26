import Foundation

/// Reads any JSON an IPA repository is published as.
///
/// There is no standard. The shapes in the wild:
///
/// - **AltStore / SideStore / AltStore PAL / SpotC** — `{ name, identifier,
///   apps: [ { bundleIdentifier, version, downloadURL, versions: [...] } ] }`
/// - **GBox** — `{ sourceName, sourceImage, apps: [ { name, version,
///   downloadURL } ] }` (apps often carry no bundle ID)
/// - **Scarlet** — either the store shape above, or top-level *categories*:
///   `{ "META": {...}, "Tweaked": [ { name, bundleID, down, icon, dev } ], ... }`
/// - **E-Sign / Feather / generic** — a bare array of app objects, with `url`
///   or `link` for the download and `icon` for the art
///
/// Everything is read through `JSONSerialization` into Foundation objects and
/// interpreted field by field, with aliases, so a repository that names a field
/// differently still lists its apps.
enum SourceParser {

    /// A document after parsing: what it calls itself, and its apps.
    struct Parsed {
        var name: String?
        var icon: String?
        var featured: [String] = []
        var entries: [MarketEntry]
    }

    /// The shapes recognised, for the log and the source row.
    enum Format: String {
        case altStore = "AltStore"
        case appsObject = "apps"
        case categoryMap = "categories"
        case appArray = "list"
        case unknown = "unknown"
    }

    static func parse(_ data: Data, sourceName fallback: String,
                      sourceID: String) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let array = root as? [Any] {
            let entries = entries(in: array, sourceID: sourceID, sourceName: fallback, category: nil)
            guard !entries.isEmpty else { return nil }
            return Parsed(name: nil, icon: nil, entries: entries)
        }
        guard let dict = root as? [String: Any] else { return nil }

        let displayName = string(dict, ["name", "sourceName", "title", "repoName"]) ?? fallback
        let featured = (dict["featuredApps"] as? [Any])?.compactMap { $0 as? String } ?? []
        let icon = string(dict, ["iconURL", "icon", "sourceImage", "image", "repoIcon"])
            ?? meta(dict)?["icon"].flatMap { $0 as? String }

        // `apps` as an array (AltStore, GBox) or as a dictionary keyed by id.
        if let list = dict["apps"] as? [Any] {
            let entries = entries(in: list, sourceID: sourceID, sourceName: displayName, category: nil)
            guard !entries.isEmpty else { return nil }
            return Parsed(name: displayName, icon: icon, featured: featured, entries: entries)
        }
        if let map = dict["apps"] as? [String: Any] {
            let entries = entries(in: Array(map.values), sourceID: sourceID,
                                  sourceName: displayName, category: nil)
            guard !entries.isEmpty else { return nil }
            return Parsed(name: displayName, icon: icon, entries: entries)
        }
        // Some wraps put the list one level down.
        for key in ["data", "list", "result", "items"] {
            if let list = dict[key] as? [Any] {
                let entries = entries(in: list, sourceID: sourceID, sourceName: displayName, category: nil)
                if !entries.isEmpty { return Parsed(name: displayName, icon: icon, entries: entries) }
            }
        }
        // Scarlet's category map: every value that is an array of app objects.
        var collected: [MarketEntry] = []
        for (key, value) in dict {
            guard key != "META", let list = value as? [Any] else { continue }
            collected += entries(in: list, sourceID: sourceID, sourceName: displayName, category: key)
        }
        guard !collected.isEmpty else { return nil }
        return Parsed(name: displayName, icon: icon, entries: collected)
    }

    /// Which shape a document is, without building entries — used for the
    /// source row's label.
    static func format(of data: Data) -> Format {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return .unknown }
        if root is [Any] { return .appArray }
        guard let dict = root as? [String: Any] else { return .unknown }
        if dict["apps"] is [Any] { return .altStore }
        if dict["apps"] is [String: Any] { return .appsObject }
        for key in ["data", "list", "result", "items"] where dict[key] is [Any] { return .appsObject }
        let arrays = dict.values.filter { $0 is [Any] }.count
        return arrays > 0 ? .categoryMap : .unknown
    }

    // MARK: - App objects

    /// Only dictionaries that look like an app: a name and something to
    /// download. That's what keeps a repository's `news` or `permissions`
    /// arrays from being read as apps.
    private static func entries(in list: [Any], sourceID: String,
                                sourceName: String, category: String?) -> [MarketEntry] {
        list.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return entry(dict, sourceID: sourceID, sourceName: sourceName, category: category)
        }
    }

    private static func entry(_ dict: [String: Any], sourceID: String,
                              sourceName: String, category: String?) -> MarketEntry? {
        let name = string(dict, ["name", "title", "appName", "CFBundleDisplayName"])
        // A download link is what makes an app installable; without one there's
        // nothing to do with the row.
        let releases = versions(dict, sourceID: sourceID, sourceName: sourceName)
        guard !releases.isEmpty else { return nil }
        let identifier = string(dict, ["bundleIdentifier", "bundleID", "bundleId",
                                       "CFBundleIdentifier", "packageName", "package"])
            ?? name.map { "\(sourceID)#\($0.lowercased())" }
            ?? "\(sourceID)#\(releases[0].id)"
        // Screenshots are published under a few names; some sources nest them
        // inside the release rather than the app.
        let screenshots = strings(dict, ["screenshots", "screenshotURLs", "images", "screenshot"])
            ?? (dict["versions"] as? [Any])?.last.flatMap { item -> [String]? in
                guard let version = item as? [String: Any] else { return nil }
                return strings(version, ["screenshots", "screenshotURLs"])
            } ?? []
        let notes = string(dict, ["versionDescription", "changelog", "releaseNotes"])
            ?? (dict["versions"] as? [Any])?.last.flatMap { item -> String? in
                guard let version = item as? [String: Any] else { return nil }
                return string(version, ["localizedDescription", "versionDescription"])
            }
        return MarketEntry(id: identifier,
                           name: name ?? releases[0].version ?? identifier,
                           developer: string(dict, ["developerName", "dev", "developer", "author", "authorName"]),
                           subtitle: string(dict, ["subtitle", "localizedDescription",
                                                   "description", "information"]),
                           icon: string(dict, ["iconURL", "icon", "image", "iconUrl", "appIcon"]),
                           category: string(dict, ["category", "section", "genre"]) ?? category ?? "",
                           versions: releases,
                           screenshots: screenshots,
                           notes: notes)
    }

    /// A `versions` array when there is one, else the app's own release.
    private static func versions(_ dict: [String: Any], sourceID: String,
                                 sourceName: String) -> [MarketEntry.Version] {
        var out: [MarketEntry.Version] = []
        if let listed = dict["versions"] as? [Any] {
            for item in listed {
                guard let version = item as? [String: Any] else { continue }
                guard let link = string(version, ["downloadURL", "down", "download", "url", "link"]),
                      let url = URL(string: link) else { continue }
                out.append(.init(id: url.absoluteString,
                                 version: string(version, ["version", "versionString", "tag"]),
                                 date: date(version, ["date", "versionDate", "published", "created"]),
                                 size: size(version, ["size", "fileSize"]),
                                 url: url.absoluteString,
                                 minOS: string(version, ["minOSVersion", "minimumOS", "minOS"]),
                                 sourceID: sourceID,
                                 sourceName: sourceName))
            }
        }
        if out.isEmpty,
           let link = string(dict, ["downloadURL", "down", "download", "url", "link", "ipa"]),
           let url = URL(string: link) {
            out.append(.init(id: url.absoluteString,
                             version: string(dict, ["version", "versionString", "tag"]),
                             date: date(dict, ["versionDate", "date", "updated", "published"]),
                             size: size(dict, ["size", "fileSize"]),
                             url: url.absoluteString,
                             minOS: string(dict, ["minOSVersion", "minimumOS", "minOS"]),
                             sourceID: sourceID,
                             sourceName: sourceName))
        }
        // Newest first, but a repository needn't sort: order by date when given.
        if out.count > 1, out.contains(where: { $0.date != nil }) {
            out.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        return out
    }

    // MARK: - Field readers

    private static func meta(_ dict: [String: Any]) -> [String: Any]? {
        dict["META"] as? [String: Any]
    }

    private static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            switch dict[key] {
            case let text as String where !text.isEmpty:
                return text
            case let number as NSNumber:
                return number.stringValue
            default:
                continue
            }
        }
        // Scarlet-ish documents nest the app's own details.
        if let meta = meta(dict) {
            for key in keys {
                if let text = meta[key] as? String, !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static func strings(_ dict: [String: Any], _ keys: [String]) -> [String]? {
        for key in keys {
            if let list = dict[key] as? [String], !list.isEmpty { return list }
            if let list = dict[key] as? [Any] {
                let cleaned = list.compactMap { $0 as? String }.filter { !$0.isEmpty }
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private static func size(_ dict: [String: Any], _ keys: [String]) -> Int64? {
        for key in keys {
            if let number = dict[key] as? NSNumber { return number.int64Value }
            if let text = dict[key] as? String {
                // "12.4 MB" is common in hand-written repositories.
                let digits = text.replacingOccurrences(of: ",", with: ".")
                if let bytes = Int64(digits) { return bytes }
                let upper = digits.uppercased()
                let multipliers: [(String, Double)] = [("GB", 1_073_741_824),
                                                       ("MB", 1_048_576),
                                                       ("KB", 1_024)]
                for (suffix, factor) in multipliers where upper.hasSuffix(suffix) {
                    let number = Double(upper.replacingOccurrences(of: suffix, with: "")
                        .trimmingCharacters(in: .whitespaces)) ?? 0
                    return Int64(number * factor)
                }
            }
        }
        return nil
    }

    private static func date(_ dict: [String: Any], _ keys: [String]) -> Date? {
        for key in keys {
            guard let text = dict[key] as? String else {
                if let seconds = dict[key] as? Double { return Date(timeIntervalSince1970: seconds) }
                continue
            }
            if let date = iso.date(from: text) { return date }
            if let date = day.date(from: text) { return date }
        }
        return nil
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
