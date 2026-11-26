import Foundation

/// Reads a **whole-account** Telegram Desktop export and lists every channel in
/// it, so the studio can offer them instead of asking for handles one at a time.
///
/// A full export is Settings › Advanced › Export Telegram data with "include
/// everything" ticked: its `result.json` carries `chats.list` — every dialog the
/// account has, with its public username where there is one — and `messages`
/// tagged with the peer they belong to. That's the only way to see the account's
/// channel list without a signed-in client, which this build doesn't have.
enum TelegramDiscovery {

    /// One channel the export knew about.
    struct Found: Identifiable, Equatable {
        /// The export's peer id, stable across exports of the same account.
        let id: String
        let title: String
        /// The public handle, when the channel has one. Without it the channel
        /// can't be read from this app at all.
        let handle: String?
        /// Telegram's type string: `public_channel`, `private_group`, …
        let kind: String
        /// Messages in it that carry an `.ipa`.
        let ipaCount: Int

        var isAddable: Bool { handle?.isEmpty == false }
        var isChannel: Bool { kind.contains("channel") }
    }

    struct Account {
        let title: String
        let found: [Found]
        var ipaFiles: Int { found.reduce(0) { $0 + $1.ipaCount } }
        var addable: [Found] { found.filter(\.isAddable) }
    }

    enum Failure: LocalizedError {
        case notAnExport
        case noChannels

        var errorDescription: String? {
            switch self {
            case .notAnExport:
                return L("That isn't a Telegram export. In Telegram Desktop, choose Settings › Advanced › Export Telegram data, tick everything, and pick the result.json it writes.")
            case .noChannels:
                return L("The export lists no channels. A full export includes them under “chats” — a single chat's export doesn't.")
            }
        }
    }

    /// `json` is the export's `result.json`.
    static func read(_ json: URL) throws -> Account {
        guard let data = try? Data(contentsOf: json),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["messages"] != nil || root["chats"] != nil
        else { throw Failure.notAnExport }

        let accountTitle = (root["name"] as? String) ?? L("This account")

        // Every dialog the export lists, including ones already left. A chat
        // export of a single channel has no list, and is handled at the end.
        var chats: [String: (title: String, handle: String?, kind: String)] = [:]
        for key in ["chats", "left_chats"] {
            guard let container = root[key] as? [String: Any],
                  let list = container["list"] as? [Any] else { continue }
            for item in list {
                guard let chat = item as? [String: Any],
                      let type = chat["type"] as? String else { continue }
                let id = peerKey(chat["id"])
                guard !id.isEmpty else { continue }
                chats[id] = (
                    title: (chat["name"] as? String) ?? id,
                    handle: (chat["username"] as? String)?.trimmingCharacters(in: .whitespaces),
                    kind: type
                )
            }
        }

        // Count the .ipa-carrying messages per peer.
        var ipaCounts: [String: Int] = [:]
        for item in (root["messages"] as? [Any]) ?? [] {
            guard let message = item as? [String: Any] else { continue }
            guard let name = message["file_name"] as? String,
                  name.lowercased().hasSuffix(".ipa") else { continue }
            let peer = peerKey(message["peer_id"] ?? message["from_id"])
            ipaCounts[peer == "" ? "-" : peer, default: 0] += 1
        }

        // A single-channel export: no chat list, so the JSON's own name is the
        // channel and every .ipa belongs to it.
        if chats.isEmpty {
            let fallback = ipaCounts.values.reduce(0, +)
            guard fallback > 0 else { throw Failure.notAnExport }
            let handle = (root["username"] as? String) ?? (root["name"] as? String)
            let found = Found(id: "single", title: accountTitle,
                              handle: handle, kind: "channel", ipaCount: fallback)
            return Account(title: accountTitle, found: [found])
        }

        // Channels, and anything else carrying .ipa files: a group that
        // publishes builds is worth listing even though it can't be scanned.
        var found: [Found] = chats.compactMap { key, chat in
            let count = ipaCounts[key] ?? 0
            let isChannel = chat.kind.contains("channel")
            guard isChannel || count > 0 else { return nil }
            return Found(id: key, title: chat.title, handle: chat.handle,
                         kind: chat.kind, ipaCount: count)
        }
        guard !found.isEmpty else { throw Failure.noChannels }
        // IPAs first, then channels, then the rest; ties by name.
        found.sort { lhs, rhs in
            if lhs.ipaCount != rhs.ipaCount { return lhs.ipaCount > rhs.ipaCount }
            if lhs.isChannel != rhs.isChannel { return lhs.isChannel }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return Account(title: accountTitle, found: found)
    }

    /// `channel123456` and `123456` are the same peer, and the export uses both.
    private static func peerKey(_ raw: Any?) -> String {
        let text: String
        if let number = raw as? NSNumber { text = number.stringValue }
        else if let string = raw as? String { text = string }
        else { return "" }
        let digits = text.filter(\.isNumber)
        return digits.isEmpty ? text : digits
    }
}
