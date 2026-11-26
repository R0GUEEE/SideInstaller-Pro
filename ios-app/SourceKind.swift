import Foundation

/// The kinds of repository SideInstaller can read.
///
/// One format is universal — the AltStore/SideStore JSON catalogue — and every
/// store that publishes a source uses it, so most of this is labelling: the
/// same parser, told which store the link came from so the UI can say "E-Sign"
/// rather than "source", and so a bare link can be recognised as a GitHub
/// release feed and read without one.
enum SourceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// An AltStore-format JSON catalogue (the format Feather, SideStore, E-Sign
    /// and the rest all publish).
    case altSource
    /// A GitHub repository whose releases carry `.ipa` assets.
    case github
    /// A public Telegram channel whose posts carry `.ipa` documents.
    case telegram

    var id: String { rawValue }

    var title: String {
        switch self {
        case .altSource: return L("AltStore source")
        case .github:    return L("GitHub releases")
        case .telegram:  return L("Telegram channel")
        }
    }

    /// The stores whose links people paste. Not a limit — any host works — just
    /// the ones worth recognising, so a link opens with a sensible label and the
    /// right hint in the add sheet.
    enum Store: String, CaseIterable, Identifiable {
        case altStore, sideStore, eSign, feather, scarlet, esignHub, other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .altStore:  return "AltStore"
            case .sideStore: return "SideStore"
            case .eSign:     return "E-Sign"
            case .feather:   return "Feather"
            case .scarlet:   return "Scarlet"
            case .esignHub:  return "E-Sign Hub"
            case .other:     return L("Other")
            }
        }

        /// The scheme its own `…://source?url=` links use, when it has one.
        var schemes: [String] {
            switch self {
            case .altStore:  return ["altstore"]
            case .sideStore: return ["sidestore"]
            case .eSign:     return ["esign", "esignplus"]
            case .feather:   return ["feather"]
            case .scarlet:   return ["scarlet"]
            default:         return []
            }
        }

        /// Hosts that belong to the store itself (not the many community
        /// repositories that publish AltStore-format JSON).
        var hosts: [String] {
            switch self {
            case .altStore:  return ["altstore.io"]
            case .sideStore: return ["sidestore.io", "sidestore.github.io"]
            case .eSign:     return ["esign.yyyue.xyz", "esign.flycoding.cn"]
            case .feather:   return ["feather.ioshaven.com"]
            case .scarlet:   return ["scarlet.ioshaven.com"]
            case .esignHub:  return ["esignhub.dev", "t.me", "telegram.me"]
            case .other:     return []
            }
        }

        static func of(host: String?) -> Store {
            guard let host = host?.lowercased() else { return .other }
            for store in allCases {
                if store.hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return store
                }
            }
            return .other
        }
    }
}

/// What a source was recognised as when it was added.
struct SourceOrigin: Codable, Sendable, Equatable {
    var kind: SourceKind
    /// The store it came from, when one was recognised.
    var store: String

    var storeName: String { SourceKind.Store(rawValue: store)?.title ?? SourceKind.Store.other.title }

    /// Reads a link before it's fetched: its scheme names a store, and so does
    /// the `altstore://source?url=` style wrapper.
    static func detect(_ text: String) -> SourceOrigin {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           let store = SourceKind.Store.allCases.first(where: { $0.schemes.contains(scheme) }) {
            return SourceOrigin(kind: .altSource, store: store.rawValue)
        }
        let host = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)?.host
        let store = SourceKind.Store.of(host: host)
        if isGitHubReleaseFeed(host) {
            return SourceOrigin(kind: .github, store: SourceKind.Store.other.rawValue)
        }
        if isTelegramChannel(host) {
            return SourceOrigin(kind: .telegram, store: SourceKind.Store.esignHub.rawValue)
        }
        return SourceOrigin(kind: .altSource, store: store.rawValue)
    }

    /// A `t.me/<channel>` or `t.me/s/<channel>` link.
    static func isTelegramChannel(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "t.me" || host == "telegram.me" || host == "www.t.me"
    }

    /// `github.com/<owner>/<repo>` — a repository, not a file in one.
    static func isGitHubReleaseFeed(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "github.com" || host == "www.github.com"
    }
}
