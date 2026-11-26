import Foundation

// The marketplace's row model: one app, with every release the sources carry
// for it. Kept apart from the parser so both the parser and the store can name
// it without importing each other.

struct MarketEntry: Identifiable, Sendable, Codable {

    /// One downloadable release.
    struct Version: Identifiable, Sendable, Codable, Equatable {
        /// The download URL doubles as the identity: it's what makes a release
        /// distinct across sources.
        let id: String
        let version: String?
        let date: Date?
        let size: Int64?
        /// Where it downloads from.
        let url: String
        let minOS: String?
        /// The source carrying it, so the page can name it and the row can
        /// filter by source.
        let sourceID: String
        let sourceName: String
        /// False for a release whose link is a page — a Telegram post, say —
        /// rather than the file itself. Those open in their app instead of
        /// downloading here.
        var direct: Bool = true

        var link: URL? { URL(string: url) }

        var needsNewerOS: Bool {
            guard let major = Int((minOS ?? "").split(separator: ".").first ?? "") else { return false }
            return major > ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        }
    }

    /// The bundle ID, or the name for a source that doesn't give one.
    let id: String
    var name: String
    var developer: String?
    var subtitle: String?
    var icon: String?
    var category: String
    /// Newest first.
    var versions: [Version]
    /// App Store-style screenshots the source publishes, in order.
    var screenshots: [String] = []
    /// The release notes for the newest version, when the source gives any.
    var notes: String?

    var screenshotURLs: [URL] { screenshots.compactMap { URL(string: $0) } }

    var latest: Version? { versions.first }
    var iconURL: URL? { URL(string: icon ?? "") }
    var date: Date? { latest?.date }
    var size: Int64? { latest?.size }

    /// The release a chosen one picks out, or the newest.
    func release(_ chosen: Version?) -> Version? {
        guard let chosen else { return latest }
        return versions.first { $0.id == chosen.id } ?? latest
    }
}
