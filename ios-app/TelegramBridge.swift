import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A third-party bridge that reads a Telegram channel and republishes it as RSS,
/// with the files themselves served alongside.
///
/// This is the workaround for channels that publish no web preview: Telegram's
/// own `t.me/s/…` page is empty for them, and only a signed-in client would see
/// the posts. `tg.i-c-a.su` does have such a client, and publishes
/// `https://tg.i-c-a.su/rss/<channel>` — an RSS feed whose `<enclosure>` entries
/// are the `.ipa` files, at `https://tg.i-c-a.su/media/<channel>/<message>/<name>`.
///
/// Those links download **the file itself**, not a page, so what they produce is
/// installable — verified against three channels whose previews are off.
///
/// The trade-off is honest: the bridge is somebody else's service. It can be
/// down, rate-limited, or stop; nothing here depends on it alone, and the
/// preview read and Desktop exports still work without it.
enum TelegramBridge {

    static let host = "https://tg.i-c-a.su"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The channel's feed, as entries. Throws when the bridge has nothing.
    static func entries(channel: String, limit: Int = 100)
        async throws -> (name: String, entries: [MarketEntry]) {
        // The feed takes `?limit=`, and answers far more than its default ten
        // when asked (99 items at limit=100, measured). It 500s under load, so a
        // failed request is retried once and then tried without the limit — ten
        // posts beat an unreadable channel.
        var xml: String?
        for candidate in [max(10, limit), max(10, limit), 0] {
            guard let url = URL(string: candidate == 0
                                ? "\(host)/rss/\(channel)"
                                : "\(host)/rss/\(channel)?limit=\(candidate)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            request.setValue("SideInstaller", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            if (200...299).contains(http.statusCode), data.count < 8 << 20,
               let text = String(data: data, encoding: .utf8), text.contains("<item") {
                xml = text
                break
            }
            if http.statusCode == 404 {
                throw Failure(message: L("@%@ isn't on the bridge either.", channel))
            }
            // Anything else is worth one more try, then the plain feed.
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        guard let xml else {
            throw Failure(message: L("The Telegram bridge couldn't be reached for @%@.", channel))
        }

        let title = firstMatch(#"<channel>\s*<title>(?:<!\[CDATA\[)?([^<\]]*)"#, in: xml)
            .map(decodeEntities) ?? "@\(channel)"
        // The channel's own picture, used for any app without a preview image.
        let channelIcon = firstMatch(#"<image>\s*<url>([^<]+)"#, in: xml)
            .map(decodeEntities) ?? "\(host)/icon/\(channel)/icon.jpg"

        var entries: [MarketEntry] = []
        var seen = Set<String>()
        for item in components(#"<item>(.*?)</item>"#, in: xml) {
            let itemTitle = firstMatch(#"<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>"#, in: item)
                .map(decodeEntities)
                .map(cleanTitle)
            // The enclosure is the file: url, type and length.
            guard let enclosure = firstMatch(#"<enclosure\s+url="([^"]+)""#, in: item),
                  let link = URL(string: decodeEntities(enclosure)),
                  link.pathExtension.lowercased() == "ipa" else { continue }
            let length = firstMatch(#"<enclosure[^>]*length="(\d+)""#, in: item).flatMap { Int64($0) }
            let published = firstMatch(#"<pubDate>([^<]+)</pubDate>"#, in: item).flatMap { rfc822.date(from: $0) }
            let fileName = link.lastPathComponent.removingPercentEncoding ?? link.lastPathComponent
            guard seen.insert(fileName.lowercased()).inserted else { continue }

            // Each item carries its own preview image beside the file. That's
            // the closest thing to an app icon Telegram publishes.
            let thumb = item.range(of: #"media/[^"]*/preview/[^"&\s]+"#, options: .regularExpression)
                .map { String(item[$0]) }
                .map { "\(host)/\($0)" }
            let name = itemTitle ?? String(fileName.dropLast(4))
            let version = versionNumber(in: fileName) ?? versionNumber(in: name)
            entries.append(MarketEntry(id: "tg-bridge:\(channel):\(name.lowercased())",
                                       name: name,
                                       developer: "@\(channel)",
                                       subtitle: nil,
                                       icon: thumb ?? channelIcon,
                                       category: "Telegram",
                                       versions: [.init(id: link.absoluteString,
                                                        version: version,
                                                        date: published,
                                                        size: length,
                                                        url: link.absoluteString,
                                                        minOS: nil,
                                                        sourceID: "telegram:\(channel)",
                                                        sourceName: title,
                                                        direct: true)]))
        }
        guard !entries.isEmpty else {
            throw Failure(message: L("The bridge lists no .ipa files for @%@.", channel))
        }
        return (title, entries)
    }

    /// "[Media] Athlytic: Fitness & Recovery" → "Athlytic: Fitness & Recovery".
    private static func cleanTitle(_ raw: String) -> String {
        var text = raw
        for prefix in ["[Media]", "[Document]", "[Video]", "[Photo]"] {
            if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix(".ipa") { text.removeLast(4) }
        return text.isEmpty ? raw : text
    }

    /// "Oxford_Dictionary_v16_8_Premium_Unlock.ipa" → "16.8".
    private static func versionNumber(in text: String) -> String? {
        guard let range = text.range(of: #"v?\d+\.\d+(\.\d+)?"#, options: .regularExpression)
        else { return nil }
        var found = String(text[range])
        if found.hasPrefix("v") { found.removeFirst() }
        return found
    }

    // MARK: - Small XML helpers

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func components(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}
