import Combine
import Foundation
import Security

/// The Telegram side's authorization stories, and exactly how far each one goes.
///
/// Three ways to feed the Telegram studio, in increasing order of setup:
///
/// 1. **Public previews** — nothing to set up, works now, recent posts only,
///    channels with previews off can't be read (`TelegramStudio.scan`).
/// 2. **A channel export** — Telegram Desktop's "Export chat history" as JSON.
///    Every message, every file, offline; the files themselves can be imported
///    and installed. No account touches this app.
/// 3. **An MTProto login** — an account session, which is the only way to read a
///    private channel or download a file in-app. It needs api credentials from
///    my.telegram.org, a phone login with its code and 2FA, and a session key on
///    the device. `TelegramCredentials` below handles the credentials half; the
///    client itself is not in this build.
@MainActor
final class TelegramCredentials: ObservableObject {

    static let shared = TelegramCredentials()

    /// Telegram's own registration page: api_id and api_hash come from here.
    static let registrationURL = URL(string: "https://my.telegram.org/apps")!

    /// What Telegram issued for this install, kept in the Keychain.
    struct Credentials: Equatable {
        let apiID: Int
        let apiHash: String
    }

    @Published private(set) var credentials: Credentials?
    /// Set when saving fails, for the form to show.
    @Published private(set) var lastError: String?

    private static let service = "com.sideinstaller.telegram"

    private init() {
        credentials = Self.load()
    }

    var isConfigured: Bool { credentials != nil }

    /// Saves the pair, after checking it's shaped like Telegram's.
    ///
    /// An `api_id` is a small integer; an `api_hash` is 32 hex characters.
    /// Both come from my.telegram.org/apps, registered for this app.
    @discardableResult
    func save(apiID: String, apiHash: String) -> Bool {
        let idText = apiID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hashText = apiHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let id = Int(idText), id > 0, id < 100_000_000 else {
            lastError = L("An api_id is a number, like 1234567.")
            return false
        }
        guard hashText.count == 32,
              hashText.allSatisfy({ $0.isHexDigit }) else {
            lastError = L("An api_hash is 32 letters and digits, like 0123456789abcdef0123456789abcdef.")
            return false
        }
        guard Self.write("\(id):\(hashText)") else {
            lastError = L("Couldn't save to the Keychain.")
            return false
        }
        credentials = Credentials(apiID: id, apiHash: hashText)
        lastError = nil
        return true
    }

    func clear() {
        Self.delete()
        credentials = nil
    }

    // MARK: Keychain

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "api"]
    }

    private static func load() -> Credentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = Int(parts[0]) else { return nil }
        return Credentials(apiID: id, apiHash: String(parts[1]))
    }

    private static func write(_ text: String) -> Bool {
        let data = Data(text.utf8)
        let update = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Reads a Telegram Desktop chat export — the JSON its "Export chat history"
/// writes — and pulls the `.ipa` files out of it.
///
/// This is the offline alternative to an account: the export names every file,
/// the files themselves sit next to the JSON, and a local file can be installed
/// through the same `file://` path the generated source uses.
enum TelegramExport {

    struct Summary {
        var channel: String
        var entries: [MarketEntry]
        /// Messages looked at, for the report.
        var messages: Int
        /// Files the export lists that aren't beside the JSON.
        var missingFiles: Int
    }

    enum Failure: LocalizedError {
        case notAnExport
        case noIPA

        var errorDescription: String? {
            switch self {
            case .notAnExport:
                return L("That isn't a Telegram export. In Telegram Desktop, open the channel, then ⋮ › Export chat history › JSON.")
            case .noIPA:
                return L("That export has no .ipa files in it.")
            }
        }
    }

    /// `json` is the export's `result.json`; files are looked up beside it.
    static func read(_ json: URL) throws -> Summary {
        guard let data = try? Data(contentsOf: json),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [Any]
        else { throw Failure.notAnExport }
        let channel = (root["name"] as? String) ?? json.deletingLastPathComponent().lastPathComponent
        let folder = json.deletingLastPathComponent()

        var entries: [MarketEntry] = []
        var missing = 0
        for item in messages {
            guard let message = item as? [String: Any] else { continue }
            // A document carries `file`/`file_name`; photos and stickers don't.
            guard let fileName = message["file_name"] as? String,
                  fileName.lowercased().hasSuffix(".ipa") else { continue }
            let date = (message["date"] as? String).flatMap { iso.date(from: $0) }
            let size = (message["file_size"] as? NSNumber)?.int64Value
            let relative = (message["file"] as? String) ?? "files/\(fileName)"
            let fileURL = folder.appendingPathComponent(relative)
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            if !exists { missing += 1 }

            let name = fileName.hasSuffix(".ipa") ? String(fileName.dropLast(4)) : fileName
            let body = (message["text"] as? String)
                ?? (message["text"] as? [Any])?.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
            let identifier = "telegram-export:\(channel.lowercased()):\(name.lowercased())"
            let version = firstVersion(in: name) ?? firstVersion(in: body)

            var versions: [MarketEntry.Version] = []
            if exists {
                versions.append(.init(id: fileURL.absoluteString,
                                      version: version, date: date, size: size,
                                      url: fileURL.absoluteString, minOS: nil,
                                      sourceID: "telegram-export:\(channel)",
                                      sourceName: channel, direct: true))
            }
            versions.append(.init(id: "export://\(channel)/\(name)",
                                  version: version, date: date, size: size,
                                  url: exists ? fileURL.absoluteString
                                              : "https://t.me/\(channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? channel)",
                                  minOS: nil,
                                  sourceID: "telegram-export:\(channel)",
                                  sourceName: channel,
                                  direct: exists))
            entries.append(MarketEntry(id: identifier,
                                       name: name,
                                       developer: "@\(channel)",
                                       subtitle: body?.split(separator: "\n").first.map(String.init),
                                       icon: nil,
                                       category: "Telegram",
                                       versions: versions))
        }
        guard !entries.isEmpty else { throw Failure.noIPA }
        entries.sort { ($0.latest?.date ?? .distantPast) > ($1.latest?.date ?? .distantPast) }
        return Summary(channel: channel, entries: entries, messages: messages.count,
                       missingFiles: missing)
    }

    private static func firstVersion(in text: String?) -> String? {
        guard let text else { return nil }
        guard let range = text.range(of: #"v?\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        var found = String(text[range])
        if found.hasPrefix("v") { found.removeFirst() }
        return found
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
