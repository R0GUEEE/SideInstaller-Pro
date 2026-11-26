import SwiftUI
import UIKit

// MARK: - Models

/// One provisioning profile, decoded from the CMS blob misagent returns.
///
/// The CMS signature isn't verified (the device already trusts installed
/// profiles). The plist payload is found by scanning the blob, as StikDebug
/// does, rather than using `CMSDecoder`.
struct ProvisioningProfile: Identifiable, @unchecked Sendable, Equatable {

    /// Apple's name for the App ID the profile was issued against, e.g.
    /// "SideStore" — not the app's display name, though they usually match.
    let appIDName: String
    /// The full `TEAMID.bundle.id` from the profile's entitlements. This is the
    /// App ID as the developer portal knows it, and may end in `*`.
    let applicationIdentifier: String
    let teamName: String
    let uuid: String
    let creationDate: Date?
    let expirationDate: Date?
    /// Entitlements granted by the profile, as a plist dictionary.
    let entitlements: [String: Any]

    var id: String { uuid }

    /// Compares identity only (UUID and expiry); `[String: Any]` isn't `Equatable`.
    static func == (lhs: ProvisioningProfile, rhs: ProvisioningProfile) -> Bool {
        lhs.uuid == rhs.uuid && lhs.expirationDate == rhs.expirationDate
    }

    /// The bundle ID without the team prefix:
    /// `A1B2C3D4E5.com.example.app` → `com.example.app`.
    var bundleIdentifier: String {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else {
            return applicationIdentifier
        }
        return String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
    }

    /// The team prefix on its own, or nil when the identifier has no prefix.
    var teamIdentifier: String? {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else { return nil }
        return String(applicationIdentifier[..<dot])
    }

    /// True when the App ID is a wildcard (ends in `*`).
    var isWildcard: Bool { applicationIdentifier.hasSuffix("*") }

    /// Calendar days until expiry (1 = tomorrow); negative once expired.
    var daysRemaining: Int? {
        guard let expirationDate else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day],
                                       from: calendar.startOfDay(for: Date()),
                                       to: calendar.startOfDay(for: expirationDate)).day
    }

    var isExpired: Bool {
        guard let expirationDate else { return false }
        return expirationDate < Date()
    }

    /// Entitlement keys to display, excluding the four every profile has.
    var capabilityKeys: [String] {
        let boilerplate: Set<String> = [
            "application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
            "get-task-allow",
        ]
        return entitlements.keys.filter { !boilerplate.contains($0) }.sorted()
    }

    /// Decodes a `.mobileprovision` payload. Returns nil if no readable plist is
    /// found; such profiles are left off the page.
    init?(data: Data) {
        guard let payload = Self.plistPayload(in: data),
              let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil),
              let dict = plist as? [String: Any] else { return nil }

        let entitlements = dict["Entitlements"] as? [String: Any] ?? [:]
        self.entitlements = entitlements
        self.appIDName = dict["AppIDName"] as? String ?? ""
        self.applicationIdentifier = entitlements["application-identifier"] as? String ?? ""
        self.teamName = dict["TeamName"] as? String ?? ""
        self.uuid = dict["UUID"] as? String ?? UUID().uuidString
        self.creationDate = dict["CreationDate"] as? Date
        self.expirationDate = dict["ExpirationDate"] as? Date
    }

    /// Find the plist inside the CMS wrapper: XML between `<?xml` and `</plist>`,
    /// or everything from `bplist00` on. Apple has shipped both.
    private static func plistPayload(in data: Data) -> Data? {
        let xmlStart = Data("<?xml".utf8)
        let xmlEnd = Data("</plist>".utf8)
        if let start = data.range(of: xmlStart),
           let end = data.range(of: xmlEnd, options: [], in: start.lowerBound..<data.endIndex) {
            return data[start.lowerBound..<end.upperBound]
        }
        if let start = data.range(of: Data("bplist00".utf8)) {
            return data[start.lowerBound..<data.endIndex]
        }
        return nil
    }
}

/// One app installation_proxy reported, kept only when it was installed with a
/// provisioning profile — sideloaded, or a TestFlight build.
struct SideloadedApp: Identifiable, Equatable, @unchecked Sendable {

    /// Sideloaded or TestFlight; App Store apps aren't listed.
    let kind: Kind

    let bundleID: String
    let name: String
    let version: String?
    /// `TEAMID.bundle.id` from the app's signed entitlements. When missing,
    /// profile matching falls back to the bundle ID.
    let applicationIdentifier: String?

    var id: String { bundleID }

    /// How an app got onto the device, from what `installation_proxy` reports.
    enum Kind: String, CaseIterable, Sendable {
        /// Signed with a provisioning profile and installed by something like
        /// SideInstaller, AltStore or Xcode.
        case sideloaded
        /// A TestFlight build. It carries a beta-reports-active entitlement the
        /// profile grants, which a sideloaded app never has.
        case testFlight
        /// Installed from the App Store (or shipped with iOS).
        case appStore

        var title: String {
            switch self {
            case .sideloaded: return L("Sideloaded")
            case .testFlight: return L("TestFlight")
            case .appStore:   return L("App Store")
            }
        }

        /// The label each row shows under the app's name.
        var rowSubtitle: String {
            switch self {
            case .sideloaded: return L("Sideloaded")
            case .testFlight: return L("TestFlight")
            case .appStore:   return L("App Store")
            }
        }
    }

    /// The app's kind. A TestFlight build is the one case that needs looking at
    /// entitlements: `beta-reports-active` comes from testers' profiles.
    static func kind(of plist: [String: Any]) -> Kind {
        let entitlements = plist["Entitlements"] as? [String: Any]
        if entitlements?["beta-reports-active"] != nil { return .testFlight }
        return plist["ProfileValidated"] != nil ? .sideloaded : .appStore
    }

    /// Every app of a kind the page lists, or nil for one it doesn't.
    /// `ProfileValidated` is what marks an app as installed with a profile —
    /// sideloaded or TestFlight, not App Store.
    init?(plist: [String: Any], kinds: Set<Kind> = [.sideloaded, .testFlight]) {
        guard let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }
        let kind = SideloadedApp.kind(of: plist)
        guard kinds.contains(kind) else { return nil }
        self.kind = kind
        self.bundleID = bundleID
        let display = plist["CFBundleDisplayName"] as? String
        let bundleName = plist["CFBundleName"] as? String
        self.name = display?.isEmpty == false ? display! : (bundleName?.isEmpty == false ? bundleName! : bundleID)
        self.version = plist["CFBundleShortVersionString"] as? String
        let entitlements = plist["Entitlements"] as? [String: Any]
        self.applicationIdentifier = entitlements?["application-identifier"] as? String
    }
}

/// An installed app with every profile on the device that could have signed it,
/// latest expiry first. Multiple profiles are normal: each re-sign leaves one.
struct SideloadedAppStatus: Identifiable, Equatable, @unchecked Sendable {

    let app: SideloadedApp
    let profiles: [ProvisioningProfile]

    var id: String { app.bundleID }

    /// The profile in use: the one that expires last.
    var current: ProvisioningProfile? { profiles.first }

    /// Profiles kept only for history, shown on the detail page.
    var superseded: [ProvisioningProfile] { Array(profiles.dropFirst()) }

    /// Sort key: expiry date. Apps without a profile sort last.
    var sortKey: Date { current?.expirationDate ?? .distantFuture }
}

/// Expiry urgency bands and colors (same as AltStore/StikDebug), scaled to a
/// free profile's seven days.
enum ExpiryUrgency {
    case expired, critical, soon, later, comfortable, unknown

    static func of(_ profile: ProvisioningProfile?) -> ExpiryUrgency {
        guard let profile, let days = profile.daysRemaining else { return .unknown }
        if profile.isExpired { return .expired }
        switch days {
        case ...1:  return .critical
        case 2...3: return .soon
        case 4...5: return .later
        default:    return .comfortable
        }
    }

    var color: Color {
        switch self {
        case .expired, .critical: return .red
        case .soon:               return .orange
        case .later:              return .yellow
        case .comfortable:        return .green
        case .unknown:            return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .expired:  return "exclamationmark.triangle.fill"
        case .critical: return "clock.badge.exclamationmark.fill"
        case .unknown:  return "questionmark.circle"
        default:        return "clock.fill"
        }
    }

    /// Expiry text, e.g. "Expires today", "Expires in 5 days — 23 Aug",
    /// "Expired 12 Aug". More than 30 days out shows only the date.
    static func text(for profile: ProvisioningProfile?) -> String {
        guard let profile, let expiration = profile.expirationDate else {
            return L("No matching profile")
        }
        let formatted = expiration.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Localizer.locale))
        if profile.isExpired { return L("Expired %@", formatted) }
        switch profile.daysRemaining {
        case 0:            return L("Expires today")
        case 1:            return L("Expires tomorrow")
        case .some(2...30): return L("Expires in %d days — %@", profile.daysRemaining ?? 0, formatted)
        default:           return L("Expires %@", formatted)
        }
    }
}

// MARK: - Matching

/// Matches installed apps to the profiles that signed them. Static functions
/// with no device or UI state, so the logic can be tested on its own.
enum ProfileMatcher {

    /// Index every profile by the App ID it was issued against, then hand each
    /// app the ones that could have signed it.
    static func match(apps: [SideloadedApp],
                      profiles: [ProvisioningProfile]) -> (entries: [SideloadedAppStatus],
                                                           unmatched: [ProvisioningProfile]) {
        let sorted = profiles.sorted { expiry($0) > expiry($1) }
        // A wildcard App ID covers every bundle id under it, so those can't be
        // looked up — they have to be tried against each app in turn.
        let wildcards = sorted.filter(\.isWildcard)
        let specific = sorted.filter { !$0.isWildcard }
        let byAppID = Dictionary(grouping: specific, by: \.applicationIdentifier)
        // Also index by bundle ID, for apps that don't report
        // `application-identifier`.
        let byBundleID = Dictionary(grouping: specific, by: \.bundleIdentifier)

        var claimed = Set<String>()
        let entries = apps.map { app -> SideloadedAppStatus in
            let matched = matchingProfiles(for: app, byAppID: byAppID,
                                           byBundleID: byBundleID, wildcards: wildcards)
            claimed.formUnion(matched.map(\.uuid))
            return SideloadedAppStatus(app: app, profiles: matched)
        }

        // Profiles no app matched (deleted apps, unused wildcards). Shown because
        // they count toward a free account's App ID limit.
        let unmatched = sorted.filter { !claimed.contains($0.uuid) }

        return (entries.sorted(by: order), unmatched)
    }

    /// Soonest expiry first, then by name.
    private static func order(_ lhs: SideloadedAppStatus, _ rhs: SideloadedAppStatus) -> Bool {
        if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
        return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
    }

    /// The profiles that could have signed `app`, latest expiry first.
    ///
    /// Profiles for this exact App ID or bundle ID take priority. Wildcards are
    /// used only when there are none, so a long-lived wildcard can't hide an
    /// app-specific profile's earlier expiry.
    private static func matchingProfiles(for app: SideloadedApp,
                                         byAppID: [String: [ProvisioningProfile]],
                                         byBundleID: [String: [ProvisioningProfile]],
                                         wildcards: [ProvisioningProfile]) -> [ProvisioningProfile] {
        let target = app.applicationIdentifier ?? app.bundleID
        let specific = (byAppID[target] ?? []) + (byBundleID[app.bundleID] ?? [])
        if !specific.isEmpty { return deduplicated(specific) }
        return deduplicated(wildcards.filter { covers(pattern: $0.applicationIdentifier, app) })
    }

    /// Whether a wildcard App ID covers this app. Checks the app's identifier
    /// first, then its bundle ID against the pattern without the team prefix.
    static func covers(pattern: String, _ app: SideloadedApp) -> Bool {
        if let identifier = app.applicationIdentifier, matches(pattern: pattern, identifier) {
            return true
        }
        guard let dot = pattern.firstIndex(of: ".") else {
            return matches(pattern: pattern, app.bundleID)
        }
        return matches(pattern: String(pattern[pattern.index(after: dot)...]), app.bundleID)
    }

    /// Does `pattern` — an App ID that may end in `*` — cover `value`?
    static func matches(pattern: String, _ value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        return value.range(of: "^" + escaped + "$", options: .regularExpression) != nil
    }

    /// Removes duplicate profiles (the two indexes overlap) and sorts by latest
    /// expiry.
    private static func deduplicated(_ profiles: [ProvisioningProfile]) -> [ProvisioningProfile] {
        var seen = Set<String>()
        return profiles
            .filter { seen.insert($0.uuid).inserted }
            .sorted { expiry($0) > expiry($1) }
    }

    private static func expiry(_ profile: ProvisioningProfile) -> Date {
        profile.expirationDate ?? .distantPast
    }

    /// Whether an installed app was built from the IPA with `ipaBundleID`.
    /// isideload signs apps as `<bundle id>.<team id>`, so this checks for that
    /// suffix: `teamID` when known, otherwise any 10-character team ID.
    static func installed(_ bundleID: String, isBuiltFrom ipaBundleID: String,
                          teamID: String?) -> Bool {
        if bundleID == ipaBundleID { return true }        // signed by something else
        if let teamID, !teamID.isEmpty { return bundleID == "\(ipaBundleID).\(teamID)" }
        guard bundleID.hasPrefix(ipaBundleID + ".") else { return false }
        let suffix = bundleID.dropFirst(ipaBundleID.count + 1)
        // A team id is ten characters, upper-case letters and digits only.
        return suffix.count == 10 && suffix.allSatisfy { $0.isUppercase || $0.isNumber }
    }
}

/// One app a refresh will act on: what is installed, and the IPA on disk it
/// will be signed again from.
struct RefreshJob: Identifiable, Equatable {

    enum State: Equatable {
        case pending, working, done
        case failed(String)
    }

    /// The bundle id as installed — team id and all.
    let bundleID: String
    let name: String
    let ipa: URL
    /// Team ID the app is currently signed under (from its current profile).
    let teamID: String?
    var state: State = .pending

    var id: String { bundleID }
}

// MARK: - Manager

/// Drives the Sideloaded apps page: loads installed apps and profiles from the
/// device, matches them, and runs "Refresh all" through the install pipeline.
@MainActor
final class SideloadedAppsManager: ObservableObject {

    @Published private(set) var entries: [SideloadedAppStatus] = []
    /// Profiles belonging to no installed app — deleted apps' leftovers.
    @Published private(set) var unmatched: [ProvisioningProfile] = []
    @Published private(set) var isWorking = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastRefreshed: Date?
    @Published var lastError: String?

    /// The apps a refresh can act on: an installed app whose IPA is still in
    /// Documents. Rebuilt on every load.
    @Published private(set) var refreshable: [RefreshJob] = []
    /// The refreshable jobs by bundle ID, so a row doesn't scan the list.
    @Published private(set) var jobsByBundle: [String: RefreshJob] = [:]
    /// How many installed apps of each kind the device reports.
    @Published private(set) var kindCounts: [SideloadedApp.Kind: Int] = [:]
    /// Installed apps' icons, by bundle ID. Read from the device once and kept
    /// on disk, so the list doesn't re-fetch them on every launch.
    @Published private(set) var icons: [String: UIImage] = [:]
    /// Apps on the page with no IPA to sign again from, for the note that says
    /// why they aren't included.
    @Published private(set) var unrefreshable = 0
    /// The run in progress, or the last one's results until another starts.
    @Published private(set) var jobs: [RefreshJob] = []
    @Published private(set) var isRefreshing = false
    /// What the refresh is doing right now, shown on the button.
    @Published private(set) var refreshStatus: String?
    /// How the last finished run went, e.g. "Refreshed 2 of 3 apps."
    @Published private(set) var refreshSummary: String?

    private var engine: Engine { Engine.shared }

    /// Keeps `autoLoad` to a single attempt.
    private var didAutoLoad = false

    /// The refresh in flight, kept so it can be called off between apps.
    private var refreshTask: Task<Void, Never>?

    /// What went wrong last, as a popup `RootView` stacks over the app.
    var popups: [ToolPopup] { lastError.map { [.error($0)] } ?? [] }

    func closePopup(_ popup: ToolPopup) { lastError = nil }

    /// Number of apps expiring within a day (shown in the header pill).
    var expiringSoon: Int {
        entries.filter { status in
            switch ExpiryUrgency.of(status.current) {
            case .expired, .critical: return true
            default: return false
            }
        }.count
    }

    /// Shows the last list read from this device straight away, and reads it
    /// again in the background only when that's cheap.
    ///
    /// Opening the page used to open the device link — start LocalDevVPN, wait
    /// for the tunnel, walk a pairing handshake — before a single app appeared.
    /// None of that is needed to show what was already read: the list is cached
    /// per device, and an explicit Load or pull-to-refresh does the real read.
    /// An automatic re-read happens only if the link is already open, so it
    /// costs one query and no connection.
    func autoLoad() {
        guard !didAutoLoad else { return }
        if !hasLoaded, let cached = Self.cachedInventory() {
            adopt(cached)
        }
        engine.refreshNetworkStatus()
        guard engine.vpnConnected,
              !engine.isRunning,
              engine.connection.isConnected else { return }
        didAutoLoad = true
        load(quiet: true)
    }

    /// What the device said last time, per device, rendered on the same path as
    /// a live read.
    private func adopt(_ cached: CachedInventory) {
        // Parsing the profile blobs and matching them to apps is the expensive
        // part — a few hundred profiles with property lists inside each. It
        // runs off the main actor, so the tab draws its frame first.
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Parsed in
                Self.parse(cached.apps, cached.profiles)
            }.value
            entries = result.matched.entries
            unmatched = result.matched.unmatched
            kindCounts = result.counts
            hasLoaded = true
            lastRefreshed = cached.date
            await rebuildRefreshable()
            loadIcons(for: result.apps.map(\.bundleID))
            engine.log("Sideloaded apps: showing \(result.apps.count) from the last read, \(Self.since(cached.date)).")
        }
    }

    /// Apps, profiles and the match between them — everything the page needs,
    /// worked out away from the main actor.
    struct Parsed {
        let apps: [SideloadedApp]
        let matched: (entries: [SideloadedAppStatus], unmatched: [ProvisioningProfile])
        /// How many of each kind the device has, for the section headers.
        let counts: [SideloadedApp.Kind: Int]
    }

    nonisolated static func parse(_ appPlists: [[String: Any]], _ profileBlobs: [Data]) -> Parsed {
        let apps = appPlists.compactMap {
            SideloadedApp(plist: $0, kinds: [.sideloaded, .testFlight])
        }
        let profiles = profileBlobs.compactMap(ProvisioningProfile.init(data:))
        var counts: [SideloadedApp.Kind: Int] = [:]
        for app in apps { counts[app.kind, default: 0] += 1 }
        return Parsed(apps: apps, matched: ProfileMatcher.match(apps: apps, profiles: profiles),
                      counts: counts)
    }

    private static func since(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Ask the device what it has. `quiet` logs failures instead of showing them.
    func load(quiet: Bool = false) {
        guard !isWorking, !isRefreshing else { return }
        isWorking = true
        lastError = nil
        if !quiet { engine.log("=== Sideloaded apps: reading the device ===") }
        Task {
            do {
                let inventory = try await engine.sideloadedAppInventory()
                Self.cache(inventory.apps, inventory.profiles)
                let result = await Task.detached(priority: .userInitiated) {
                    Self.parse(inventory.apps, inventory.profiles)
                }.value
                let apps = result.apps
                let matched = result.matched
                entries = matched.entries
                unmatched = matched.unmatched
                kindCounts = result.counts
                await rebuildRefreshable()
                hasLoaded = true
                lastRefreshed = Date()
                loadIcons(for: apps.map(\.bundleID))
                engine.log("Sideloaded apps: \(apps.count) sideloaded, \(inventory.profiles.count) profile(s) decoded.")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                if quiet {
                    engine.log("Sideloaded apps: not ready yet (\(message))")
                } else {
                    lastError = message
                    engine.log("⛔️ Sideloaded apps: \(message)")
                }
            }
            isWorking = false
        }
    }

    // MARK: - The last read

    /// The device's inventory as it last answered, so the page can draw it
    /// without opening the link. Keyed by UDID, so two devices never mix.
    struct CachedInventory: Codable {
        let apps: [[String: Any]]
        let profiles: [Data]
        let date: Date

        enum CodingKeys: String, CodingKey { case apps, profiles, date }

        init(apps: [[String: Any]], profiles: [Data], date: Date) {
            self.apps = apps
            self.profiles = profiles
            self.date = date
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let data = try container.decode(Data.self, forKey: .apps)
            apps = ((try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [[String: Any]]) ?? []
            profiles = try container.decode([Data].self, forKey: .profiles)
            date = try container.decode(Date.self, forKey: .date)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // Plists hold Any; JSON doesn't, and this is what the device sent.
            let data = try PropertyListSerialization.data(fromPropertyList: apps,
                                                          format: .binary, options: 0)
            try container.encode(data, forKey: .apps)
            try container.encode(profiles, forKey: .profiles)
            try container.encode(date, forKey: .date)
        }
    }

    private static var inventoryFile: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let device = Engine.shared.deviceUDID ?? "unknown"
        let safe = device.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "device"
        return base.appendingPathComponent("AppInventory-\(safe).plist")
    }

    static func cache(_ apps: [[String: Any]], _ profiles: [Data]) {
        let cached = CachedInventory(apps: apps, profiles: profiles, date: Date())
        guard let data = try? PropertyListEncoder().encode(cached) else { return }
        try? data.write(to: inventoryFile, options: .atomic)
    }

    static func cachedInventory() -> CachedInventory? {
        guard let data = try? Data(contentsOf: inventoryFile),
              let cached = try? PropertyListDecoder().decode(CachedInventory.self, from: data)
        else { return nil }
        return cached
    }

    // MARK: - Icons

    func icon(for bundleID: String) -> UIImage? { icons[bundleID] }

    /// The job that would re-sign this app, if it can be refreshed in place.
    func job(for bundleID: String) -> RefreshJob? { jobsByBundle[bundleID] }

    private static var iconDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AppIcons", isDirectory: true)
    }

    private static func iconFile(for bundleID: String) -> URL {
        let safe = bundleID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "icon"
        return iconDirectory.appendingPathComponent(String(safe.suffix(120)) + ".png")
    }

    /// Fills the icon column: cached PNGs first, then one batched round trip for
    /// whatever is missing.
    ///
    /// Icons used to be fetched one at a time, each opening its own
    /// `app_service` connection — a handshake per app, with the list stuck on
    /// placeholders meanwhile. One connection serves the whole batch, and the
    /// cache means only the first launch pays for it.
    private func loadIcons(for bundleIDs: [String]) {
        let missing = bundleIDs.filter { icons[$0] == nil }
        guard !missing.isEmpty else { return }
        Task {
            var wanted: [String] = []
            for bundleID in missing {
                if let cached = Self.cachedIcon(bundleID) {
                    await MainActor.run { self.icons[bundleID] = cached }
                } else {
                    wanted.append(bundleID)
                }
            }
            guard !wanted.isEmpty else { return }
            // Batches of 40: one connection each, and the list fills in as they
            // come back rather than all at once at the end.
            for chunk in stride(from: 0, to: wanted.count, by: 40).map({
                Array(wanted[$0..<min($0 + 40, wanted.count)])
            }) {
                guard let fetched = try? await engine.appIcons(bundleIDs: chunk) else { continue }
                var decoded: [String: UIImage] = [:]
                for (bundleID, data) in fetched {
                    guard let image = UIImage(data: data) else { continue }
                    decoded[bundleID] = image
                    try? FileManager.default.createDirectory(at: Self.iconDirectory,
                                                             withIntermediateDirectories: true)
                    try? data.write(to: Self.iconFile(for: bundleID), options: .atomic)
                }
                guard !decoded.isEmpty else { continue }
                await MainActor.run {
                    for (bundleID, image) in decoded { self.icons[bundleID] = image }
                }
            }
        }
    }

    /// Fills the icon column from what's already on disk, without asking the
    /// device. Called when the list appears: a list restored from the last
    /// session shouldn't show placeholder squares until the next read.
    func preloadIcons() {
        let ids = entries.map(\.app.bundleID)
        guard !ids.isEmpty else { return }
        loadIcons(for: ids)
    }

    private static func cachedIcon(_ bundleID: String) -> UIImage? {
        guard let data = try? Data(contentsOf: iconFile(for: bundleID)) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Refresh all

    /// Re-signs and reinstalls every refreshable app, one at a time (they share
    /// one device link and signing queue, and Apple's API is rate-limited).
    func refreshAll() {
        refresh(refreshable, summary: nil)
    }

    /// Re-signs and reinstalls one app, chosen from its row.
    func refresh(_ job: RefreshJob) {
        refresh([job], summary: nil, enforceTeam: true)
    }

    /// Re-signs one app whatever team signed it before — the case for an app
    /// installed by someone else's certificate, a wildcard one included. The
    /// new profile carries this Apple ID, and because the bundle ID doesn't
    /// change the install replaces the app rather than adding a copy.
    func resign(_ job: RefreshJob) {
        refresh([job], summary: nil, enforceTeam: false)
    }

    private func refresh(_ queue: [RefreshJob], summary: String?, enforceTeam: Bool = true) {
        guard !isRefreshing, !isWorking, !queue.isEmpty else { return }
        guard !engine.isRunning else {
            lastError = ErrorHelp.explained(L("An install is already running. Wait for it to finish, then refresh."))
            return
        }
        jobs = queue
        isRefreshing = true
        lastError = nil
        refreshSummary = nil
        refreshStatus = L("Getting ready")
        engine.log("=== Refresh all: \(jobs.count) app(s) ===")

        refreshTask = Task {
            defer {
                isRefreshing = false
                refreshStatus = nil
                refreshTask = nil
            }
            do {
                try await engine.prepareRefresh()
            } catch {
                let message = Self.text(for: error)
                lastError = message
                engine.log("⛔️ Refresh all: \(message)")
                jobs = []
                return
            }

            var refreshed = 0
            for index in jobs.indices {
                // Cancellation is checked between apps; signing and installing
                // can't be interrupted midway.
                if Task.isCancelled { break }
                let job = jobs[index]
                // Skip apps signed by a different team: the new bundle ID would
                // install a second copy instead of replacing the app.
                if enforceTeam, let team = engine.signingTeamID, let installed = job.teamID,
                   installed != team {
                    jobs[index].state = .failed(
                        L("Signed by team %@, not the one you're signed in as — refreshing it here would install a second copy.", installed))
                    continue
                }
                jobs[index].state = .working
                refreshStatus = enforceTeam ? L("Refreshing %@", job.name)
                                            : L("Re-signing %@", job.name)
                do {
                    try await engine.refreshInstalledApp(named: job.name, ipaPath: job.ipa.path)
                    jobs[index].state = .done
                    refreshed += 1
                } catch {
                    let message = Self.text(for: error)
                    jobs[index].state = .failed(message)
                    engine.log("⛔️ Refresh \(job.name): \(message)")
                }
            }

            refreshSummary = jobs.count == 1
                ? (refreshed == 1 ? L("Refreshed. Its seven days start again now.")
                                  : L("Nothing was refreshed."))
                : L("Refreshed %d of %d apps.", refreshed, jobs.count)
            engine.log("Refresh all finished: \(refreshed)/\(jobs.count) refreshed.")
            // Read the device again, so the days on screen are the new ones.
            if refreshed > 0 {
                isRefreshing = false        // `load` won't run while a refresh holds the link
                load(quiet: true)
            }
        }
    }

    /// Stops the run after the current app finishes. Remaining apps are left
    /// unchanged.
    func cancelRefresh() {
        guard isRefreshing, refreshTask != nil else { return }
        refreshTask?.cancel()
        refreshStatus = L("Stopping after this app")
        engine.log("Refresh all: stopping after the current app.")
    }

    /// A thrown error as the page should print it.
    private static func text(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Finds which listed apps have a matching IPA in Documents. The IPAs are
    /// read off the main thread.
    private func rebuildRefreshable() async {
        let installed = entries.map {
            InstalledRef(bundleID: $0.app.bundleID, name: $0.app.name,
                         teamID: $0.current?.teamIdentifier)
        }
        let matched = await Task.detached(priority: .userInitiated) {
            SideloadedAppsManager.pair(installed, with: IPALibrary.installable())
        }.value
        refreshable = matched
        jobsByBundle = Dictionary(matched.map { ($0.bundleID, $0) },
                                  uniquingKeysWith: { first, _ in first })
        unrefreshable = max(0, entries.count - matched.count)
        engine.log("Sideloaded apps: \(matched.count) of \(entries.count) can be refreshed from an IPA on disk.")
    }

    /// A page entry cut down to what the matching needs, so that work can be
    /// handed off the main actor.
    private struct InstalledRef: Sendable {
        let bundleID: String
        let name: String
        let teamID: String?
    }

    /// One job per installed app that an IPA on disk would reinstall, in the
    /// page's own order.
    private nonisolated static func pair(
        _ installed: [InstalledRef],
        with library: [(entry: IPALibrary.Entry, info: IPALibrary.AppInfo)]
    ) -> [RefreshJob] {
        installed.compactMap { app in
            guard let match = library.first(where: {
                ProfileMatcher.installed(app.bundleID, isBuiltFrom: $0.info.bundleID,
                                         teamID: app.teamID)
            }) else { return nil }
            return RefreshJob(bundleID: app.bundleID, name: app.name,
                              ipa: match.entry.url, teamID: app.teamID)
        }
    }
}

// MARK: - View

/// Sideloaded apps page: apps installed with a provisioning profile, their App
/// ID, and time until expiry. Pushed from Tools (relies on its `NavigationStack`).
struct AppsView: View {
    /// The configured sources, searched when an app might have an update.
    @ObservedObject var sources: SourceStore
    @State private var pendingUninstall: SideloadedAppStatus?
    /// The search field's text: name, bundle ID or App ID.
    @State private var search = ""
    /// How the two sections order their rows.
    @State private var sort: Sort = .expiry
    /// The app whose Info sheet is up.
    @State private var infoTarget: SideloadedAppStatus?
    /// Newest release per bundle ID across the sources, built once.
    @State private var updateCandidates: [String: (version: String, url: URL)] = [:]
    /// Observed so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer
    /// Observed for `installProgress` during a refresh.
    @EnvironmentObject private var engine: Engine
    @ObservedObject var manager: SideloadedAppsManager
    /// The debugger-backed JIT session, shown in its own card.
    @ObservedObject private var jit = JITSession.shared

    /// Shows the "Refresh all" confirmation alert.
    @State private var confirmRefresh = false
    /// The updates sheet, opened from the toolbar's download icon.
    @State private var showUpdates = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // The title sits above the search field now: with `.searchable`
                // the field is pushed up into the navigation bar and the header
                // ended up *below* it, with a gap before the list.
                header.cascadeItem(0)
                searchField.cascadeItem(1)
                jitCard
                refreshRunCard
                // Errors show as a popup, which `RootView` lays over the app.
                appList
                // The two page-wide actions live at the foot of the list now:
                // the top of the page is the search field and the apps.
                refreshAllFooter
                refreshNote
            }
            .padding(20)
            .pageColumn()
            .animation(.smooth(duration: 0.35), value: manager.entries)
            .animation(.smooth(duration: 0.3), value: manager.isWorking)
            .animation(.smooth(duration: 0.35), value: manager.jobs)
            .animation(.smooth(duration: 0.35), value: manager.refreshable)
        }
        .background(AppBackground())
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showUpdates) {
            UpdatesSheet(manager: manager, updates: updates) { batch in
                Task { await updateAll(batch.map { ($0.status, $0.version, $0.url) }) }
            }
        }
        .sheet(item: $infoTarget) { status in
            AppInfoSheet(status: status, manager: manager)
        }
        .onAppear {
            manager.autoLoad()
            manager.preloadIcons()
            refreshUpdateCandidates()
        }
        .onChange(of: sources.revision) { _, _ in refreshUpdateCandidates() }
        .onChange(of: manager.entries.count) { _, _ in refreshUpdateCandidates() }
        .confirmationDialog(L("Uninstall this app?"),
                            isPresented: Binding(get: { pendingUninstall != nil },
                                                 set: { if !$0 { pendingUninstall = nil } }),
                            presenting: pendingUninstall) { status in
            Button(L("Uninstall %@", status.app.name), role: .destructive) {
                uninstall(status)
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { status in
            Text(L("The app and everything it stored are removed from this iPhone. Its seven-day clock stops, and reinstalling it later starts a new one."))
        }
        .alert(L("Refresh all apps?"), isPresented: $confirmRefresh) {
            Button(L("Refresh all")) { manager.refreshAll() }
            Button(L("Cancel"), role: .cancel) { }
        } message: {
            Text(manager.refreshable.count == 1
                 ? L("%@ will be signed again with your Apple ID and installed over the copy on this device. It keeps its data, and its seven days start over.",
                     manager.refreshable.first?.name ?? "")
                 : L("%d apps will be signed again with your Apple ID and installed over the copies on this device. They keep their data, and their seven days start over.",
                     manager.refreshable.count))
        }
    }

    // MARK: Header

    private var header: some View {
        BrandHeader(icon: "app.badge.clock", image: "AppsLogo", title: L("My Apps"),
                    compact: true,
                    trailingActions: AnyView(HStack(spacing: 6) {
                        updatesToolbarButton
                        reloadToolbarButton
                        sortMenu
                    })) {
            if manager.hasLoaded {
                let expiring = manager.expiringSoon
                StatusPill(text: expiring > 0
                             ? (expiring == 1 ? L("%d app needs refreshing", expiring)
                                              : L("%d apps need refreshing", expiring))
                             : (manager.entries.count == 1 ? L("%d app", manager.entries.count)
                                                           : L("%d apps", manager.entries.count)),
                           systemImage: expiring > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                           color: expiring > 0 ? .orange : .green)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
            }
        }
    }

    /// The search field, in the page rather than in the navigation bar so the
    /// title can sit above it.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(L("Search installed apps"), text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .fieldBackground()
    }

    /// The sort order, beside the title with the other two actions.
    private var sortMenu: some View {
        Menu {
            Picker(L("Sort by"), selection: $sort) {
                ForEach(Sort.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent2)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.07)))
        }
    }

    // MARK: Toolbar actions

    /// What's newer in the sources, newest first — the list the sheet shows and
    /// the count the icon carries.
    private var updates: [AppUpdate] {
        manager.entries.compactMap { status in
            guard let candidate = updateCandidate(for: status) else { return nil }
            return AppUpdate(status: status, version: candidate.version, url: candidate.url)
        }
    }

    /// The updates entry point: a download symbol with how many are waiting.
    private var updatesToolbarButton: some View {
        Button { showUpdates = true } label: {
            HStack(spacing: 2) {
                Image(systemName: updates.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
                if !updates.isEmpty {
                    Text("\(updates.count)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                }
            }
        }
        .disabled(!manager.hasLoaded)
        .accessibilityLabel(updates.isEmpty
                            ? L("Updates")
                            : L("%d updates available", updates.count))
    }

    /// Reading the device again, from the toolbar so the page opens on the list.
    /// While a refresh runs it becomes the way to stop it.
    @ViewBuilder
    private var reloadToolbarButton: some View {
        if manager.isRefreshing {
            Button { manager.cancelRefresh() } label: {
                Image(systemName: "xmark.circle")
            }
            .accessibilityLabel(L("Cancel the refresh"))
        } else if manager.isWorking {
            ProgressView().controlSize(.small)
        } else {
            Button { manager.load() } label: {
                Image(systemName: manager.hasLoaded ? "arrow.clockwise" : "iphone.and.arrow.forward")
            }
            .disabled(manager.isRefreshing)
            .accessibilityLabel(manager.hasLoaded ? L("Reload") : L("Load apps"))
        }
    }

    /// Re-signing every refreshable app, under the list rather than above it.
    @ViewBuilder
    private var refreshAllFooter: some View {
        if manager.hasLoaded && !manager.refreshable.isEmpty {
            VStack(spacing: 6) {
                // Only the install step reports progress.
                if manager.isRefreshing, engine.installProgress > 0, engine.installProgress < 1 {
                    ProgressView(value: engine.installProgress)
                        .tint(Theme.accent2)
                }
                Button { confirmRefresh = true } label: {
                    HStack(spacing: 8) {
                        if manager.isRefreshing {
                            ProgressView().controlSize(.small)
                            Text(manager.refreshStatus ?? L("Getting ready"))
                                .lineLimit(1)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(L("Refresh all"))
                        }
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(manager.isRefreshing || manager.isWorking)
                Text(manager.refreshable.count == 1
                     ? L("%d app can be signed again from an IPA already on this iPhone.",
                         manager.refreshable.count)
                     : L("%d apps can be signed again from IPAs already on this iPhone.",
                         manager.refreshable.count))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 6)
            .transition(.cardAppear)
            .cascadeItem(6)
        }
    }

    /// "just now", "3 min ago", "2 h ago" — how old the shown list is.
    static func shortSince(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60:      return L("just now")
        case ..<3_600:   return L("%d min ago", Int(seconds / 60))
        case ..<86_400:  return L("%d h ago", Int(seconds / 3_600))
        default:         return L("%d d ago", Int(seconds / 86_400))
        }
    }


    // MARK: Refresh run

    /// Per-app refresh progress and results. Stays visible after the run so
    /// failures can be read.
    @ViewBuilder
    private var refreshRunCard: some View {
        if !manager.jobs.isEmpty {
            PanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Refresh all"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    // Enumerated so rows redraw on a language change.
                    ForEach(Array(manager.jobs.enumerated()), id: \.element.id) { _, job in
                        jobRow(job)
                    }
                    if let summary = manager.refreshSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(.cardAppear)
            .cascadeItem(3)
        }
    }

    private func jobRow(_ job: RefreshJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                jobIcon(job.state)
                Text(job.name)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 6)
                Text(Self.stateText(job.state))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Self.stateColor(job.state))
            }
            if case let .failed(message) = job.state {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func jobIcon(_ state: RefreshJob.State) -> some View {
        switch state {
        case .pending:  Image(systemName: "clock").foregroundStyle(.tertiary)
        case .working:  ProgressView().controlSize(.small)
        case .done:     Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:   Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private static func stateText(_ state: RefreshJob.State) -> String {
        switch state {
        case .pending: return L("Waiting")
        case .working: return L("In progress")
        case .done:    return L("Done")
        case .failed:  return L("Failed")
        }
    }

    private static func stateColor(_ state: RefreshJob.State) -> Color {
        switch state {
        case .pending, .working: return .secondary
        case .done:              return .green
        case .failed:            return .red
        }
    }

    /// Note explaining that apps without an IPA in SideInstaller can't be
    /// refreshed.
    @ViewBuilder
    private var refreshNote: some View {
        if manager.hasLoaded && manager.unrefreshable > 0 && !manager.entries.isEmpty {
            Text(manager.unrefreshable == 1
                 ? L("%d app here has no IPA in SideInstaller, so it can't be refreshed from this page. Refresh it in whatever installed it, or import its .ipa first.",
                     manager.unrefreshable)
                 : L("%d apps here have no IPA in SideInstaller, so they can't be refreshed from this page. Refresh them in whatever installed them, or import their .ipa first.",
                     manager.unrefreshable))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cascadeItem(5 + manager.entries.count)
        }
    }

    // MARK: App list

    /// The orders the list can be read in.
    enum Sort: String, CaseIterable, Identifiable {
        case expiry, name
        var id: String { rawValue }
        var title: String { self == .expiry ? L("Expiry") : L("Name") }
    }

    /// What the sections show: the entries, filtered by the search field and
    /// ordered by `sort`.
    private var filtered: [SideloadedAppStatus] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? manager.entries : manager.entries.filter {
            $0.app.name.localizedCaseInsensitiveContains(trimmed)
                || $0.app.bundleID.localizedCaseInsensitiveContains(trimmed)
                || ($0.app.applicationIdentifier ?? "").localizedCaseInsensitiveContains(trimmed)
        }
        switch sort {
        case .expiry: return base
        case .name:   return base.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        }
    }

    /// One heading's worth of apps.
    struct AppSection: Identifiable {
        let kind: SideloadedApp.Kind
        let apps: [SideloadedAppStatus]
        var id: SideloadedApp.Kind { kind }
    }

    /// TestFlight first, then sideloaded; an empty group is left out.
    private var sections: [AppSection] {
        [SideloadedApp.Kind.testFlight, .sideloaded].compactMap { kind in
            let apps = filtered.filter { $0.app.kind == kind }
            return apps.isEmpty ? nil : AppSection(kind: kind, apps: apps)
        }
    }

    @ViewBuilder
    private var appList: some View {
        if manager.hasLoaded && manager.entries.isEmpty && !manager.isWorking {
            emptyState.transition(.cardAppear)
        } else if !manager.entries.isEmpty {
            // Lazy: a device with dozens of sideloaded apps built every row up
            // front, each with a menu, an icon lookup and an expiry label.
            LazyVStack(spacing: 14) {
                HStack {
                    Text(manager.entries.count == 1
                         ? L("%d app", manager.entries.count)
                         : L("%d apps", manager.entries.count))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let refreshed = manager.lastRefreshed {
                        Text(refreshed.formatted(Date.FormatStyle(date: .omitted, time: .shortened)
                                                     .locale(Localizer.locale)))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .cascadeItem(4)
                // Grouped by how they were installed: TestFlight first, then
                // sideloaded builds, each in expiry order.
                ForEach(sections) { section in
                    HStack {
                        Label(section.kind == .testFlight ? L("TestFlight") : L("Sideloaded"),
                              systemImage: section.kind == .testFlight ? "paperplane.fill" : "signature")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(section.apps.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                    ForEach(section.apps) { status in
                        // The row opens the Info sheet rather than pushing a page:
                        // the same details, with the app's actions beside them.
                        Button {
                            infoTarget = status
                        } label: {
                            appRow(status)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { appMenu(status) }
                    }
                }
            }
        }
    }

    /// The listed apps of one kind, in the order the manager sorted them.
    private func group(of kind: SideloadedApp.Kind) -> [SideloadedAppStatus] {
        manager.entries.filter { $0.app.kind == kind }
    }

    /// Installs each newer release in turn. The engine's one-click run handles
    /// signing and installing, so this only sequences them.
    private func updateAll(_ updates: [(SideloadedAppStatus, String, URL)]) async {
        for (status, version, url) in updates {
            engine.log("Update all: \(status.app.name) → \(version).")
            engine.installLinkedIPA(url)
            // The install runs in the background; wait for it to end before the
            // next, since they share one device link.
            while engine.isRunning || engine.isImportingIPA {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// The live JIT session, with the way out of it.
    @ViewBuilder
    private var jitCard: some View {
        if case .idle = jit.state {
            EmptyView()
        } else {
            CalloutCard(tint: .orange) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("JIT session"), systemImage: "bolt.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(jitText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if jit.isActive {
                        Button(L("Stop")) {
                            Task { await jit.stop() }
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var jitText: String {
        switch jit.state {
        case .idle:
            return ""
        case .launching:
            return L("Launching suspended…")
        case .attaching:
            return L("Attaching the debugger…")
        case .running(let pid):
            return L("Debugger attached (pid %u). JIT stays on while this session is open — keep SideInstaller running.", pid)
        case .failed(let message):
            return message
        }
    }

    /// The actions an installed app offers, laid out like SideStore's: launch it,
    /// restart its seven days, re-sign it under this Apple ID whatever signed it
    /// before, reinstall it, look at its profile, or remove it.
    @ViewBuilder
    private func appMenu(_ status: SideloadedAppStatus) -> some View {
        // A TestFlight build is provisioned by Apple through the tester's
        // account; nothing here can re-sign it, and pretending otherwise would
        // replace a working beta with a copy signed for the wrong purpose.
        if status.app.kind == .testFlight {
            Button {
                launch(status)
            } label: {
                Label(L("Open"), systemImage: "arrow.up.forward.app")
            }
            Button {
                infoTarget = status
            } label: {
                Label(L("Info"), systemImage: "info.circle")
            }
            Divider()
            Button(role: .destructive) {
                pendingUninstall = status
            } label: {
                Label(L("Delete App"), systemImage: "trash")
            }
            return AnyView(EmptyView())
        }
        return AnyView(menuBody(status))
    }

    @ViewBuilder
    private func menuBody(_ status: SideloadedAppStatus) -> some View {
        Button {
            launch(status)
        } label: {
            Label(L("Open"), systemImage: "arrow.up.forward.app")
        }

        // JIT via the debugger: the app is launched suspended, attached to and
        // resumed, and the session holds the permission until it's stopped.
        if jit.isActive, jit.bundleID == status.app.bundleID {
            Button {
                Task { await jit.stop() }
            } label: {
                Label(L("Stop JIT session"), systemImage: "bolt.slash.fill")
            }
        } else {
            Button {
                Task { await jit.enable(bundleID: status.app.bundleID, name: status.app.name) }
            } label: {
                Label(L("Launch with JIT"), systemImage: "bolt.fill")
            }
        }

        Divider()

        if let job = manager.job(for: status.app.bundleID) {
            Button {
                manager.refresh(job)
            } label: {
                Label(L("Refresh (same team)"), systemImage: "arrow.clockwise")
            }
            // The same job, without the "same team" guard: for an app signed by
            // a wildcard certificate or someone else's account.
            Button {
                manager.resign(job)
            } label: {
                Label(L("Re-sign with my Apple ID"), systemImage: "signature")
            }
            Menu {
                Button {
                    manager.resign(job)
                } label: {
                    Label(L("From the stored .ipa"), systemImage: "doc")
                }
                if let update = updateCandidate(for: status) {
                    Button {
                        engine.installLinkedIPA(update.url)
                    } label: {
                        Label(L("Update to %@", update.version), systemImage: "arrow.down.circle")
                    }
                }
                // Always offered: with no newer release in the configured
                // sources, the marketplace is where to look for one.
                Button {
                    MarketplaceRouter.shared.search(status.app.bundleID)
                } label: {
                    Label(L("Find an update in the marketplace"), systemImage: "square.grid.2x2")
                }
            } label: {
                Label(L("Update or reinstall"), systemImage: "arrow.triangle.2.circlepath")
            }
        }

        Menu {
            if status.profiles.isEmpty {
                Text(L("No profile found for it"))
            }
            ForEach(status.profiles) { profile in
                Button {
                    infoTarget = status
                } label: {
                    Text("\(profile.teamName) · \(ExpiryUrgency.text(for: profile))")
                }
            }
        } label: {
            Label(L("Provisioning Profile"), systemImage: "doc.text.magnifyingglass")
        }

        Button {
            infoTarget = status
        } label: {
            Label(L("Info"), systemImage: "info.circle")
        }

        Divider()

        Button(role: .destructive) {
            pendingUninstall = status
        } label: {
            Label(L("Delete App"), systemImage: "trash")
        }
    }

    private func launch(_ status: SideloadedAppStatus) {
        Haptics.tap()
        Task {
            do {
                try await engine.launchApp(bundleID: status.app.bundleID, name: status.app.name)
            } catch {
                manager.lastError = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            }
        }
    }

    private func uninstall(_ status: SideloadedAppStatus) {
        pendingUninstall = nil
        Haptics.destructive()
        Task {
            do {
                try await engine.uninstallApp(bundleID: status.app.bundleID,
                                              name: status.app.name)
                manager.load(quiet: true)
            } catch {
                manager.lastError = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            }
        }
    }

    /// The newest release in any configured source, per app, worked out when the
    /// sources or the installed apps change. Asking per row meant walking every
    /// source's catalogue on every layout pass — the largest list here has ten
    /// thousand apps.
    private func refreshUpdateCandidates() {
        var best: [String: (version: String, url: URL)] = [:]
        for entry in sources.entries {
            guard let release = entry.latest, let url = release.link,
                  let version = release.version else { continue }
            if let current = best[entry.id],
               version.compare(current.version, options: .numeric) != .orderedDescending { continue }
            best[entry.id] = (version, url)
        }
        updateCandidates = best
    }

    /// The newest release of this app, when it's newer than what's installed.
    private func updateCandidate(for status: SideloadedAppStatus) -> (version: String, url: URL)? {
        guard let candidate = updateCandidates[status.app.bundleID] else { return nil }
        // Numeric compare, so 1.10 is newer than 1.9.
        let installed = status.app.version ?? "0"
        return candidate.version.compare(installed, options: .numeric) == .orderedDescending
            ? candidate : nil
    }

    private func appRow(_ status: SideloadedAppStatus) -> some View {
        let profile = status.current
        let urgency = ExpiryUrgency.of(profile)
        return PanelCard {
            HStack(alignment: .center, spacing: 12) {
                icon(for: status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.app.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(status.app.kind.rowSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    expiryLabel(profile, urgency: urgency)
                }
                Spacer(minLength: 8)
                // The action most people come here for, one tap away: every app
                // can hand its seven days to this Apple ID, whatever signed it.
                if status.app.kind == .sideloaded, let job = manager.job(for: status.app.bundleID) {
                    Button {
                        manager.resign(job)
                    } label: {
                        Text(L("Re-sign"))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Theme.accent2.opacity(0.18)))
                            .foregroundStyle(Theme.accent2)
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.isRefreshing || engine.isRunning)
                }
                Menu {
                    appMenu(status)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The app's own icon, or its initials until the device hands one over.
    @ViewBuilder
    private func icon(for status: SideloadedAppStatus) -> some View {
        let side: CGFloat = 48
        if let image = manager.icon(for: status.app.bundleID) {
            return AnyView(Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous)))
        }
        // The device's own icon needs a read over the link; a source's icon is
        // an https URL and can be drawn at once. Better a real icon now than a
        // letter until the next device read.
        if let entry = sources.entries.first(where: { $0.id == status.app.bundleID }),
           entry.iconURL != nil {
            return AnyView(SourceIcon(url: entry.iconURL, side: side,
                                      fallback: "app.fill", corner: 11))
        }
        return AnyView(ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.brand)
            Text(String(status.app.name.prefix(1)).uppercased())
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(width: side, height: side))
    }

    /// The one line that matters: how long is left, and the date it runs out.
    @ViewBuilder
    private func expiryLabel(_ profile: ProvisioningProfile?, urgency: ExpiryUrgency) -> some View {
        HStack(spacing: 6) {
            Image(systemName: urgency.symbol)
            Text(ExpiryUrgency.text(for: profile))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(urgency.color)
        .padding(.top, 1)
    }

    private var emptyState: some View {
        PanelCard {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.app.dashed")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.brand)
                Text(L("No sideloaded apps"))
                    .font(.headline)
                Text(L("Nothing on this device was installed with a provisioning profile. App Store apps don't expire, so they aren't listed here."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Info

/// What the device says about one installed app, plus the actions that don't
/// belong in a context menu.
struct AppInfoSheet: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var engine: Engine
    let status: SideloadedAppStatus
    @ObservedObject var manager: SideloadedAppsManager
    @ObservedObject private var jit = JITSession.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    identityCard
                    profilesCard
                    jitCard
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("Info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let image = manager.icon(for: status.app.bundleID) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.brand)
                    Text(String(status.app.name.prefix(1)).uppercased())
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(status.app.name)
                    .font(.title3.weight(.semibold))
                Text(status.app.version.map { L("Version %@", $0) } ?? L("Version unknown"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var identityCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    row(L("Bundle ID"), status.app.bundleID, mono: true)
                    Button {
                        UIPasteboard.general.string = status.app.bundleID
                        Haptics.success()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("Copy the bundle ID"))
                }
                if let appID = status.app.applicationIdentifier {
                    row(L("App ID"), appID, mono: true)
                }
                row(L("Signed by"), status.current?.teamName ?? L("unknown"))
                row(L("Expires"), ExpiryUrgency.text(for: status.current))
                if status.current?.isWildcard == true {
                    Text(L("Its profile is a wildcard, so this app was never tied to its own App ID. Re-signing it here issues one for your Apple ID and replaces the app in place."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().opacity(0.15)
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = summaryText
                        Haptics.success()
                    } label: {
                        Label(L("Copy details"), systemImage: "doc.on.doc")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        shareSummary()
                    } label: {
                        Label(L("Share"), systemImage: "square.and.arrow.up")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var profilesCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Provisioning profiles"))
                    .font(.subheadline.weight(.semibold))
                if status.profiles.isEmpty {
                    Text(L("None found on the device."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(status.profiles) { profile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.teamName.isEmpty ? profile.applicationIdentifier : profile.teamName)
                            .font(.caption)
                        Text("\(profile.applicationIdentifier) · \(ExpiryUrgency.text(for: profile))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// JIT, through the debugger: the app is launched suspended, attached to,
    /// and resumed with the session held open.
    private var jitCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("JIT"), systemImage: "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                Text(L("Launches the app under the device's debugger, which is how iOS allows it to map executable memory. The session has to stay open: closing it, or leaving SideInstaller, turns JIT off for the app."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if jit.isActive, jit.bundleID == status.app.bundleID {
                    Button(role: .destructive) {
                        Task { await jit.stop() }
                    } label: {
                        Label(L("Stop JIT session"), systemImage: "bolt.slash.fill")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await jit.enable(bundleID: status.app.bundleID, name: status.app.name) }
                    } label: {
                        Label(L("Launch with JIT"), systemImage: "bolt.fill")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(jit.isActive)
                }
                if !jit.transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(jit.transcript.suffix(6).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    /// The app's facts as text: what someone pasting a problem report needs.
    private var summaryText: String {
        var lines = [
            "\(status.app.name) — \(status.app.kind.title)",
            "Bundle ID: \(status.app.bundleID)",
        ]
        if let appID = status.app.applicationIdentifier { lines.append("App ID: \(appID)") }
        if let version = status.app.version { lines.append("Version: \(version)") }
        if let profile = status.current {
            lines.append("Signed by: \(profile.teamName.isEmpty ? "unknown" : profile.teamName)")
            lines.append("Expires: \(ExpiryUrgency.text(for: profile))")
            if let date = profile.expirationDate {
                lines.append("Expiry date: \(date.formatted(date: .abbreviated, time: .omitted))")
            }
        }
        if let cache = IPACache.cached(for: status.app.bundleID) {
            lines.append("Stored .ipa: \(cache.sizeText), kept \(cache.savedAt.formatted(date: .abbreviated, time: .omitted))")
        }
        return lines.joined(separator: "\n")
    }

    private func shareSummary() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(status.app.name)-info.txt")
        try? summaryText.write(to: url, atomically: true, encoding: .utf8)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var controller = root
        while let presented = controller.presentedViewController { controller = presented }
        controller.present(UIActivityViewController(activityItems: [url], applicationActivities: nil),
                           animated: true)
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
