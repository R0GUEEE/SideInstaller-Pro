import Combine
import Foundation

/// The settings that change behaviour rather than describe it.
///
/// Everything here is a `UserDefaults` key with a default that matches how the
/// app behaved before it existed, so an install that never opens Settings keeps
/// working. Views observe the object, so flipping a switch takes effect without
/// a relaunch.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: Sources

    /// Ask the RSS bridge when a channel has no web preview.
    @Published var bridgeEnabled: Bool { didSet { save(bridgeEnabled, "bridgeEnabled") } }
    /// Where an "every page" scan stops.
    @Published var allPagesLimit: Int { didSet { save(allPagesLimit, "allPagesLimit") } }
    /// Pages a newly added channel starts with when "every page" is off.
    @Published var defaultPages: Int { didSet { save(defaultPages, "defaultPages") } }
    /// Scan every channel when the app opens.
    @Published var scanOnLaunch: Bool { didSet { save(scanOnLaunch, "scanOnLaunch") } }

    // MARK: Local server

    @Published var serverAutoStart: Bool { didSet { save(serverAutoStart, "serverAutoStart") } }
    @Published var serverPort: Int { didSet { save(serverPort, "serverPort") } }
    /// Hold a short background grace period when the server is running.
    @Published var keepAliveOnBackground: Bool { didSet { save(keepAliveOnBackground, "keepAliveOnBackground") } }
    /// Ask iOS for periodic background rescans.
    @Published var backgroundRefresh: Bool {
        didSet {
            save(backgroundRefresh, "backgroundRefresh")
            if backgroundRefresh {
                Task { @MainActor in BackgroundKeepAlive.shared.scheduleRefresh() }
            }
        }
    }

    // MARK: Marketplace

    /// The order the marketplace opens with: name, newest, oldest or size.
    @Published var marketplaceSort: String { didSet { save(marketplaceSort, "marketplaceSort") } }
    /// Show entries whose link opens another app (Telegram posts) beside the
    /// installable ones.
    @Published var showNonDirectEntries: Bool { didSet { save(showNonDirectEntries, "showNonDirectEntries") } }

    // MARK: Installs

    /// What the Install tab starts on.
    @Published var defaultInstallSource: String { didSet { save(defaultInstallSource, "defaultInstallSource") } }
    /// Ask before a custom .ipa spends an App ID. Off by default: signing then
    /// installs without a stop, which is what a run is for.
    @Published var askBeforeAppIDCost: Bool { didSet { save(askBeforeAppIDCost, "askBeforeAppIDCost") } }

    // MARK: Persistence

    private static let prefix = "appSettings."

    private init() {
        let defaults = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: Self.prefix + key) == nil ? fallback : defaults.bool(forKey: Self.prefix + key)
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: Self.prefix + key) == nil ? fallback : defaults.integer(forKey: Self.prefix + key)
        }
        func text(_ key: String, _ fallback: String) -> String {
            defaults.string(forKey: Self.prefix + key) ?? fallback
        }
        bridgeEnabled = bool("bridgeEnabled", true)
        allPagesLimit = int("allPagesLimit", 40)
        defaultPages = int("defaultPages", 3)
        scanOnLaunch = bool("scanOnLaunch", false)
        serverAutoStart = bool("serverAutoStart", false)
        serverPort = int("serverPort", 8123)
        keepAliveOnBackground = bool("keepAliveOnBackground", true)
        backgroundRefresh = bool("backgroundRefresh", true)
        marketplaceSort = text("marketplaceSort", "name")
        showNonDirectEntries = bool("showNonDirectEntries", true)
        defaultInstallSource = text("defaultInstallSource", "sideStore")
        askBeforeAppIDCost = bool("askBeforeAppIDCost", false)
    }

    private func save<T>(_ value: T, _ key: String) {
        UserDefaults.standard.set(value, forKey: Self.prefix + key)
    }

    /// Back to how it shipped, without touching accounts, certificates or the
    /// source list.
    func reset() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
        bridgeEnabled = true
        allPagesLimit = 40
        defaultPages = 3
        scanOnLaunch = false
        serverAutoStart = false
        serverPort = 8123
        keepAliveOnBackground = true
        backgroundRefresh = true
        marketplaceSort = "name"
        showNonDirectEntries = true
        defaultInstallSource = "sideStore"
        askBeforeAppIDCost = false
    }

    /// The values as text, for the diagnostics report.
    var summary: [(key: String, value: String)] {
        [
            ("Bridge", bridgeEnabled ? "on" : "off"),
            ("All-pages limit", "\(allPagesLimit)"),
            ("Default pages", "\(defaultPages)"),
            ("Scan on launch", scanOnLaunch ? "on" : "off"),
            ("Server auto-start", serverAutoStart ? "on" : "off"),
            ("Server port", "\(serverPort)"),
            ("Background grace", keepAliveOnBackground ? "on" : "off"),
            ("Background refresh", backgroundRefresh ? "on" : "off"),
            ("Marketplace sort", marketplaceSort),
            ("Show non-direct entries", showNonDirectEntries ? "on" : "off"),
            ("Default install source", defaultInstallSource),
            ("Ask before an App ID", askBeforeAppIDCost ? "on" : "off"),
        ]
    }
}

/// What the app keeps on disk, and how to empty it.
///
/// Every folder here is regenerable: source indexes are refetched, app icons are
/// re-read from the device, generated sources are rebuilt by a scan. Nothing in
/// this list is the user's own data — the .ipa library, pairing files and
/// certificates live elsewhere and aren't offered for deletion.
enum StorageReport {

    struct Item: Identifiable {
        let name: String
        let path: URL
        let bytes: Int64
        let detail: String

        var id: String { path.path }
        var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }

    static func items() -> [Item] {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return [
            measure(L("Source indexes"), caches.appendingPathComponent("SourceIndex", isDirectory: true),
                    detail: L("One small file per source: its apps, so opening the app doesn't re-scan.")),
            measure(L("Source documents"), caches.appendingPathComponent("Sources", isDirectory: true),
                    detail: L("The JSON each source last served, kept for the ETag.")),
            measure(L("App icons"), caches.appendingPathComponent("AppIcons", isDirectory: true),
                    detail: L("Icons read from the device for My Apps.")),
            measure(L("Generated sources"), IPALibrary.documentsDir.appendingPathComponent("Telegram", isDirectory: true),
                    detail: L("telegram-source.json, rebuilt by a scan.")),
        ]
    }

    private static func measure(_ name: String, _ url: URL, detail: String) -> Item {
        Item(name: name, path: url, bytes: size(of: url), detail: detail)
    }

    static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url,
                                                             includingPropertiesForKeys: [.fileSizeKey],
                                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    static func clear(_ item: Item) {
        try? FileManager.default.removeItem(at: item.path)
    }

    static func totalText(_ items: [Item]) -> String {
        ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.bytes }, countStyle: .file)
    }
}
