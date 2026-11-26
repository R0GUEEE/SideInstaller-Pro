import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Telegram channel as a source: the `.ipa` files its posts carry.
///
/// Two readers, because Telegram gives no API without an account:
///
/// - **The channel's own preview** (`t.me/s/<channel>`) — Telegram's, always
///   current, and it shows each attached document's name and size. It does *not*
///   give a file URL (those are minted per client session), so its entries open
///   the post in Telegram.
/// - **The RSS bridge** (`tg.i-c-a.su`) — a third-party reader that republishes
///   the channel with `<enclosure>` links to the files themselves. Those
///   download the `.ipa`, so they install. It also works for channels that
///   publish no preview at all, which is otherwise unreadable.
///
/// Both are tried and merged: the bridge supplies installable links, the preview
/// supplies the newest posts.
enum TelegramSource {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The channel name in a `t.me/<channel>` or `t.me/s/<channel>` link.
    static func channel(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        switch url.host?.lowercased() {
        case "t.me", "telegram.me", "www.t.me":
            // `t.me/c/<id>/<msg>` is a private channel's internal link: no public
            // preview, and nothing an unauthenticated reader can fetch.
            guard parts.first != "c" else { return nil }
            let name = parts.first == "s" ? parts.dropFirst().first : parts.first
            guard let name, !name.isEmpty,
                  !["joinchat", "addstickers", "share", "iv"].contains(name) else { return nil }
            return name
        default:
            return nil
        }
    }

    /// The channel's apps: the bridge's installable links plus the preview's
    /// latest posts, merged and newest first.
    static func entries(channel: String, pages: Int = 1)
        async throws -> (name: String, entries: [MarketEntry]) {
        var bridged: (name: String, entries: [MarketEntry])?
        var bridgedError: Error?
        if AppSettings.shared.bridgeEnabled {
            do {
                bridged = try await TelegramBridge.entries(channel: channel)
            } catch {
                bridgedError = error
            }
        }

        var previewed: (name: String, entries: [MarketEntry])?
        var previewError: Error?
        do {
            previewed = try await previewEntries(channel: channel, pages: pages)
        } catch {
            previewError = error
        }

        guard let base = bridged ?? previewed else {
            throw bridgedError ?? previewError
                ?? Failure(message: L("@%@ couldn't be read.", channel))
        }
        var merged = base.entries
        if let preview = previewed {
            let known = Set(merged.map { $0.name.lowercased() })
            for entry in preview.entries where !known.contains(entry.name.lowercased()) {
                merged.append(entry)
            }
        }
        merged.sort { ($0.latest?.date ?? .distantPast) > ($1.latest?.date ?? .distantPast) }
        return (previewed?.name ?? base.name, merged)
    }

    // MARK: - The channel's own preview

    private static func previewEntries(channel: String, pages: Int)
        async throws -> (name: String, entries: [MarketEntry]) {
        var request = URLRequest(url: URL(string: "https://t.me/s/\(channel)")!)
        request.timeoutInterval = 25
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                         + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                throw Failure(message: L("Telegram has no public channel called @%@. Check the link, and that the channel isn't private.", channel))
            }
            // Telegram redirects `t.me/s/<channel>` to the join page when the
            // channel publishes no preview.
            if http.statusCode == 302 || http.url?.path.hasPrefix("/s/") == false {
                throw Failure(message: L("@%@ doesn't publish a web preview, so its posts can't be read here.", channel))
            }
            guard (200...299).contains(http.statusCode) else {
                throw Failure(message: L("Telegram answered %ld for @%@.", http.statusCode, channel))
            }
        }
        guard data.count < 8 << 20 else {
            throw Failure(message: L("That channel's preview is unexpectedly large."))
        }
        let html = String(decoding: data, as: UTF8.self)
        guard html.contains("tgme_widget_message") else {
            throw Failure(message: L("Telegram didn't return a channel preview for @%@. It may be private, or have previews off.", channel))
        }

        let title = firstMatch(#"<meta property="og:title" content="([^"]+)""#, in: html)
            ?? "@\(channel)"
        // The channel's own picture, so its rows aren't anonymous.
        let channelIcon = firstMatch(#"<meta property="og:image" content="([^"]+)""#, in: html)
            ?? "\(TelegramBridge.host)/icon/\(channel)/icon.jpg"

        var collected = posts(in: html)
        if pages > 1 {
            var oldest = collected.compactMap { Int($0.id) }.min()
            for _ in 1..<pages {
                guard let before = oldest else { break }
                let next = (try? await page(channel: channel, before: before)) ?? []
                let fresh = next.filter { post in !collected.contains { $0.id == post.id } }
                guard !fresh.isEmpty else { break }
                collected += fresh
                oldest = fresh.compactMap { Int($0.id) }.min() ?? oldest
            }
        }

        var entries: [MarketEntry] = []
        var seen = Set<String>()
        for post in collected {
            let direct = post.links.first { $0.pathExtension.lowercased() == "ipa" }
            let permalink = URL(string: "https://t.me/\(channel)/\(post.id)")!

            var documents = post.documents
            if documents.isEmpty, let direct {
                documents = [(name: direct.lastPathComponent, size: nil as Int64?,
                              sizeText: nil as String?)]
            }
            var pageLink: URL?
            if documents.isEmpty, direct == nil {
                guard let heading = headline(of: post.text) else { continue }
                documents = [(name: heading, size: nil as Int64?, sizeText: nil as String?)]
                pageLink = post.links.first
            }

            for document in documents {
                let name = displayName(document.name)
                guard seen.insert("\(post.id)|\(name)").inserted else { continue }
                var versions: [MarketEntry.Version] = []
                if let direct {
                    versions.append(.init(id: direct.absoluteString,
                                          version: version(in: document.name) ?? version(in: post.text),
                                          date: post.date,
                                          size: document.size ?? byteCount(document.sizeText),
                                          url: direct.absoluteString,
                                          minOS: nil,
                                          sourceID: "telegram:\(channel)",
                                          sourceName: title,
                                          direct: true))
                }
                let link = pageLink ?? permalink
                versions.append(.init(id: "tg://\(channel)/\(post.id)/\(name)",
                                      version: version(in: document.name) ?? version(in: post.text),
                                      date: post.date,
                                      size: document.size ?? byteCount(document.sizeText),
                                      url: link.absoluteString,
                                      minOS: nil,
                                      sourceID: "telegram:\(channel)",
                                      sourceName: title,
                                      direct: false))
                entries.append(MarketEntry(id: "telegram:\(channel):\(post.id):\(name.lowercased())",
                                           name: name,
                                           developer: "@\(channel)",
                                           subtitle: post.text?.split(separator: "\n").first.map(String.init),
                                           icon: channelIcon,
                                           category: "Telegram",
                                           versions: versions))
            }
        }
        guard !entries.isEmpty else {
            throw Failure(message: L("@%@ has no .ipa files in the posts Telegram shows.", channel))
        }
        return (title, entries)
    }

    /// One page of the preview, optionally ending before a message id.
    private static func page(channel: String, before: Int? = nil) async throws -> [Post] {
        var link = "https://t.me/s/\(channel)"
        if let before { link += "?before=\(before)" }
        guard let url = URL(string: link) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                         + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        return posts(in: String(decoding: data, as: UTF8.self))
    }

    // MARK: - The preview's markup

    struct Post {
        let id: String
        let date: Date?
        let text: String?
        let documents: [(name: String, size: Int64?, sizeText: String?)]
        let links: [URL]
    }

    /// One post per `tgme_widget_message_wrap`, the wrapper Telegram's own web
    /// client renders. Split on the class name, not the whole attribute: the
    /// element carries a second class.
    private static func posts(in html: String) -> [Post] {
        var out: [Post] = []
        let chunks = html.components(separatedBy: "tgme_widget_message_wrap")
        for chunk in chunks.dropFirst() {
            guard let id = firstMatch(#"data-post="[^/"]+/(\d+)""#, in: chunk) else { continue }
            let date = firstMatch(#"<time[^>]*datetime="([^"]+)""#, in: chunk).flatMap(iso.date(from:))

            var documents: [(String, Int64?, String?)] = []
            for title in matches(#"<div class="tgme_widget_message_document_title[^>]*>([^<]*)</div>"#, in: chunk) {
                let sizeText = firstMatch(#"tgme_widget_message_document_extra[^>]*>([^<]*)<"#, in: chunk)
                documents.append((decodeEntities(title), nil, sizeText.map(decodeEntities)))
            }

            let text = firstMatch(#"<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>"#, in: chunk)
                .map(stripTags)
                .map(decodeEntities)

            let links = matches(#"href="(https?://[^"]+)""#, in: chunk)
                .compactMap { URL(string: decodeEntities($0)) }
                .filter { $0.host?.contains("telegram") != true && $0.host != "t.me" }

            out.append(Post(id: id, date: date, text: text,
                            documents: documents.map { (name: $0.0, size: $0.1, sizeText: $0.2) },
                            links: links))
        }
        return out
    }

    /// The first real line of a post: how catalogue channels title their apps.
    private static func headline(of text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(separator: "\n") {
            var cleaned = String(line)
                .replacingOccurrences(of: #"[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]"#,
                                      with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 3 else { continue }
            if cleaned.lowercased().hasSuffix(" ipa") { cleaned.removeLast(4) }
            return String(cleaned.prefix(80))
        }
        return nil
    }

    /// "Naked.ipa" → "Naked"; the extension is noise in a list of apps.
    private static func displayName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".ipa") { name.removeLast(4) }
        return name.isEmpty ? raw : name
    }

    private static func version(in text: String?) -> String? {
        guard let text else { return nil }
        guard let range = text.range(of: #"v?\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        var found = String(text[range])
        if found.hasPrefix("v") { found.removeFirst() }
        return found
    }

    private static func byteCount(_ text: String?) -> Int64? {
        guard let text else { return nil }
        let upper = text.uppercased().replacingOccurrences(of: ",", with: ".")
        let value = Double(upper.replacingOccurrences(of: "GB", with: "")
            .replacingOccurrences(of: "MB", with: "")
            .replacingOccurrences(of: "KB", with: "")
            .trimmingCharacters(in: .whitespaces)) ?? 0
        if upper.contains("GB") { return Int64(value * 1_073_741_824) }
        if upper.contains("MB") { return Int64(value * 1_048_576) }
        if upper.contains("KB") { return Int64(value * 1_024) }
        return nil
    }

    // MARK: - Small HTML helpers

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        matches(pattern, in: text).first
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
