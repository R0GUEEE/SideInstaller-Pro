import Combine
import Foundation

/// Which injection framework a tweak expects. A package's `Depends` names one,
/// and the app has to load that framework beside the tweak.
enum TweakInjectorKind: String, Codable, CaseIterable, Identifiable {
    case ellekit
    case substrate
    case libhooker
    case substitute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ellekit:    return "ElleKit"
        case .substrate:  return "CydiaSubstrate"
        case .libhooker:  return "libhooker"
        case .substitute: return "Substitute"
        }
    }

    /// What a package's `Depends` calls it.
    var packageName: String {
        switch self {
        case .ellekit:    return "ellekit"
        case .substrate:  return "mobilesubstrate"
        case .libhooker:  return "libhooker"
        case .substitute: return "substitute"
        }
    }

    /// The library file name to look for when one is added by hand.
    var fileName: String {
        switch self {
        case .ellekit:    return "ellekit.dylib"
        case .substrate:  return "CydiaSubstrate"
        case .libhooker:  return "libhooker.dylib"
        case .substitute: return "libsubstitute.dylib"
        }
    }
}

extension TweakInjectorKind {
    /// The framework a library is built against, read from the libraries it
    /// links. A tweak compiled against Substrate names `libsubstrate.dylib`
    /// even when nothing in its package says so, which is the only dependency
    /// signal a bare `.dylib` has.
    static func detected(inLibraries libraries: [String]) -> TweakInjectorKind? {
        let names = libraries.map { ($0 as NSString).lastPathComponent.lowercased() }
        if names.contains(where: { $0.contains("ellekit") }) { return .ellekit }
        if names.contains(where: { $0.contains("libhooker") }) { return .libhooker }
        if names.contains(where: { $0.contains("substitute") }) { return .substitute }
        if names.contains(where: { $0.contains("substrate") }) { return .substrate }
        return nil
    }
}

/// A library the user supplied that provides one of those frameworks. Bundling
/// them isn't possible, so they're added from a copy the user already has.
struct TweakInjector: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: TweakInjectorKind
    /// Path to the copy in Application Support.
    var path: String
    /// The name it gets inside the app's `Frameworks` folder.
    var fileName: String
}

/// A tweak — a `.dylib` on its own, or a `.deb` that carries one or more.
struct Tweak: Codable, Identifiable, Equatable {

    enum Kind: String, Codable {
        case dylib
        case deb
    }

    var id = UUID()
    /// What the list calls it: the file's name, or the package's name.
    var name: String
    /// The copy in Application Support (a `.dylib` or the `.deb` itself).
    var path: String
    var kind: Kind
    /// For a `.dylib`: where the executable should load it from.
    var loadPath: String
    /// Load it if it's there rather than requiring it.
    var weak = false
    /// The injector the package says it needs, worked out when it was added.
    var requiresInjector: TweakInjectorKind?
    /// The package's own identifier, when it came out of a `.deb` — what makes
    /// "is there a newer release?" a question that can be answered.
    var identifier: String?
    /// The package version it was added at.
    var version: String?
    /// The repository it came from, when it was added from the browser, so the
    /// update check asks the repository that published it first.
    var repository: String?

    var isDeb: Bool { kind == .deb }

    /// What the list shows beside the name: `1.4` for a package, nothing for a
    /// bare library.
    var versionText: String? {
        guard let version, !version.isEmpty else { return nil }
        return version
    }

    /// The repository's host, for a caption: `havoc.app` rather than a URL.
    var repositoryHost: String? {
        guard let repository, let host = URL(string: repository)?.host else { return nil }
        return host
    }

    /// How a repository package is recognised in the configuration: its
    /// identifier when it has one, otherwise the file name.
    func matches(fileName: String, identifier: String?) -> Bool {
        if let mine = self.identifier, !mine.isEmpty, let identifier, !identifier.isEmpty {
            return mine == identifier
        }
        return (path as NSString).lastPathComponent.lowercased() == fileName.lowercased()
    }
}

/// One addition to a plist: a top-level key, its type, and its value.
struct PlistEdit: Codable, Identifiable, Equatable {

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case string, boolean, integer, array

        var id: String { rawValue }

        var title: String {
            switch self {
            case .string:  return L("Text")
            case .boolean: return L("Switch")
            case .integer: return L("Number")
            case .array:   return L("List")
            }
        }
    }

    var id = UUID()
    var key: String
    var kind: Kind = .string
    var value: String = ""

    /// The value as a plist object, or nil when it can't be one.
    var object: Any? {
        let name = key.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        switch kind {
        case .string:
            return value
        case .boolean:
            return (value as NSString).boolValue
        case .integer:
            guard let number = Int(value) else { return nil }
            return number
        case .array:
            let items = value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            return items
        }
    }
}

/// What to change about a custom `.ipa` on the way to being signed: its
/// identity, its plists, which extensions survive, the entitlements it
/// declares, and the tweaks loaded into it.
struct AppConfig: Codable, Equatable {

    /// The four identity fields, which follow the build unless overridden.
    enum IdentityField: String, CaseIterable, Codable {
        case bundleIdentifier, displayName, version, build

        var title: String {
            switch self {
            case .bundleIdentifier: return L("Bundle ID")
            case .displayName:      return L("Display name")
            case .version:          return L("Version")
            case .build:            return L("Build")
            }
        }
    }

    /// New `CFBundleIdentifier`. Extensions and watch apps are re-prefixed.
    var bundleIdentifier = ""
    var displayName = ""
    var version = ""
    var build = ""
    /// Extra or replacement top-level keys in the app's `Info.plist`.
    var plistEdits: [PlistEdit] = []
    /// Keys written into the app's archived entitlements file.
    var entitlements: [PlistEdit] = []
    /// `PlugIns` entries to leave out, by their bundle's name (`Widget.appex`).
    var disabledExtensions: [String] = []
    /// Drop every extension instead of naming them.
    var stripExtensions = false
    var stripWatchApp = false
    var tweaks: [Tweak] = []
    /// The identity fields the user set themselves. The others always show —
    /// and apply — whatever the build being installed says, so importing another
    /// app never carries the last one's name and version along.
    var pinnedIdentity: [String] = []
    /// How libraries are named and where they're put. Optional so a saved
    /// configuration from before the choice existed still decodes.
    /// Nin/auto switch for the sideload-detection patch: nil means "when
    /// detection was found", true/false is the user's answer.
    var detectionBypass: Bool?
    var injectionBase: InjectionBase?
    var injectionFolder: InjectionFolder?
    /// Bumped when the shape changes, so old saved configurations are ignored
    /// rather than decoded wrong.
    var schema = 3

    /// True when the patch should run: asked for, or left on automatic and
    /// something was detected.
    var bypassesSideloadDetection: Bool { detectionBypass ?? false }

    var injectionBaseKind: InjectionBase { injectionBase ?? .executablePath }
    var injectionFolderKind: InjectionFolder { injectionFolder ?? .frameworks }

    /// The load path a library gets under the current choice: the same folder
    /// the injector copies it into.
    func injectionPath(for library: String) -> String {
        switch injectionFolderKind {
        case .frameworks: return "\(injectionBaseKind.rawValue)/Frameworks/\(library)"
        case .root:       return "\(injectionBaseKind.rawValue)/\(library)"
        }
    }

    func isPinned(_ field: IdentityField) -> Bool {
        pinnedIdentity.contains(field.rawValue)
    }

    mutating func setPinned(_ field: IdentityField, _ pinned: Bool) {
        var set = Set(pinnedIdentity)
        if pinned { set.insert(field.rawValue) } else { set.remove(field.rawValue) }
        pinnedIdentity = Array(set).sorted()
    }

    /// The identity field's value, for the key path the editor writes through.
    subscript(field: IdentityField) -> String {
        get {
            switch field {
            case .bundleIdentifier: return bundleIdentifier
            case .displayName:      return displayName
            case .version:          return version
            case .build:            return build
            }
        }
        set {
            switch field {
            case .bundleIdentifier: bundleIdentifier = newValue
            case .displayName:      displayName = newValue
            case .version:          version = newValue
            case .build:            build = newValue
            }
        }
    }

    var isActive: Bool {
        !bundleIdentifier.trimmed.isEmpty || !displayName.trimmed.isEmpty
            || !version.trimmed.isEmpty || !build.trimmed.isEmpty
            || !plistEdits.isEmpty || !entitlements.isEmpty
            || !disabledExtensions.isEmpty || stripExtensions || stripWatchApp
            || bypassesSideloadDetection
            || !tweaks.isEmpty
    }

    /// One line per change, for the Install screen's summary.
    var summary: [String] {
        var out: [String] = []
        if !bundleIdentifier.trimmed.isEmpty { out.append(L("Bundle ID: %@", bundleIdentifier.trimmed)) }
        if !displayName.trimmed.isEmpty { out.append(L("Name: %@", displayName.trimmed)) }
        if !version.trimmed.isEmpty { out.append(L("Version: %@", version.trimmed)) }
        if !build.trimmed.isEmpty { out.append(L("Build: %@", build.trimmed)) }
        if !plistEdits.isEmpty { out.append(L("%d plist keys", plistEdits.count)) }
        if !entitlements.isEmpty { out.append(L("%d entitlements", entitlements.count)) }
        if stripExtensions { out.append(L("All extensions removed")) }
        if !disabledExtensions.isEmpty { out.append(L("%d extensions removed", disabledExtensions.count)) }
        if stripWatchApp { out.append(L("Watch app removed")) }
        if bypassesSideloadDetection { out.append(L("Sideload detection bypass")) }
        for tweak in tweaks {
            out.append(tweak.isDeb ? L("Tweak (deb): %@", tweak.name) : L("Tweak: %@", tweak.name))
        }
        return out
    }

    /// The identity that will be registered as an App ID, when one was set.
    var resultingBundleIdentifier: String? {
        bundleIdentifier.trimmed.isEmpty ? nil : bundleIdentifier.trimmed
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A common iOS capability, as the keys that grant it.
///
/// A capability is not a switch the app can flip on its own: it writes the
/// plist key and the entitlement, and the profile Apple issues still decides
/// what's actually granted. The panel says so rather than pretending.
enum AppCapability: String, CaseIterable, Identifiable {
    case documentBrowser
    case backgroundAudio
    case backgroundLocation
    case increasedMemory
    case wifiInfo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documentBrowser:    return L("Document browser")
        case .backgroundAudio:    return L("Background audio")
        case .backgroundLocation: return L("Background location")
        case .increasedMemory:    return L("Increased memory limit")
        case .wifiInfo:           return L("Wi-Fi network info")
        }
    }

    var detail: String {
        switch self {
        case .documentBrowser:    return L("Files app access: UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace.")
        case .backgroundAudio:    return L("Keeps playing when backgrounded: UIBackgroundModes gains audio.")
        case .backgroundLocation: return L("Location updates while backgrounded: UIBackgroundModes gains location.")
        case .increasedMemory:    return L("Raises the memory ceiling on devices that allow it (entitlement).")
        case .wifiInfo:           return L("Reads the connected network's SSID (entitlement).")
        }
    }

    var icon: String {
        switch self {
        case .documentBrowser:    return "folder.badge.gearshape"
        case .backgroundAudio:    return "waveform"
        case .backgroundLocation: return "location.circle"
        case .increasedMemory:    return "memorychip"
        case .wifiInfo:           return "wifi"
        }
    }

    /// `Info.plist` keys, and whether they're a list the value joins.
    var plistKeys: [(key: String, value: String, isArray: Bool)] {
        switch self {
        case .documentBrowser:
            return [("UIFileSharingEnabled", "true", false),
                    ("LSSupportsOpeningDocumentsInPlace", "true", false)]
        case .backgroundAudio:
            return [("UIBackgroundModes", "audio", true)]
        case .backgroundLocation:
            return [("UIBackgroundModes", "location", true)]
        default:
            return []
        }
    }

    var entitlementKeys: [String] {
        switch self {
        case .increasedMemory: return ["com.apple.developer.kernel.increased-memory-limit"]
        case .wifiInfo:        return ["com.apple.developer.networking.wifi-info"]
        default:               return []
        }
    }
}

extension AppConfigStore {

    /// True when every key this capability writes is already in the
    /// configuration — entries the user wrote by hand count too.
    func isEnabled(_ capability: AppCapability) -> Bool {
        for entry in capability.plistKeys {
            guard let edit = config.plistEdits.first(where: { $0.key == entry.key }),
                  edit.value.contains(entry.value) else { return false }
        }
        for key in capability.entitlementKeys where !config.entitlements.contains(where: { $0.key == key }) {
            return false
        }
        return true
    }

    /// Adds the keys the capability needs, or takes back exactly the ones it
    /// wrote — a list value is removed from the list, not the whole list.
    func set(_ enabled: Bool, for capability: AppCapability) {
        for entry in capability.plistKeys {
            if enabled {
                upsertPlist(key: entry.key, value: entry.value, isArray: entry.isArray)
            } else {
                removePlistValue(key: entry.key, value: entry.value, isArray: entry.isArray)
            }
        }
        for key in capability.entitlementKeys {
            if enabled {
                if !config.entitlements.contains(where: { $0.key == key }) {
                    config.entitlements.append(PlistEdit(key: key, kind: .boolean, value: "true"))
                }
            } else {
                config.entitlements.removeAll { $0.key == key }
            }
        }
    }

    private func upsertPlist(key: String, value: String, isArray: Bool) {
        guard let index = config.plistEdits.firstIndex(where: { $0.key == key }) else {
            config.plistEdits.append(PlistEdit(key: key,
                                              kind: isArray ? .array : .boolean,
                                              value: value))
            return
        }
        guard isArray else { return }
        var items = config.plistEdits[index].value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !items.contains(value) else { return }
        items.append(value)
        config.plistEdits[index].value = items.joined(separator: ", ")
    }

    private func removePlistValue(key: String, value: String, isArray: Bool) {
        guard let index = config.plistEdits.firstIndex(where: { $0.key == key }) else { return }
        guard isArray else {
            config.plistEdits.remove(at: index)
            return
        }
        var items = config.plistEdits[index].value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != value }
        if items.isEmpty {
            config.plistEdits.remove(at: index)
        } else {
            config.plistEdits[index].value = items.joined(separator: ", ")
        }
    }
}

/// How an injected library is named in the executable's load command.
enum InjectionBase: String, CaseIterable, Identifiable, Codable {
    case executablePath = "@executable_path"
    case rpath = "@rpath"

    var id: String { rawValue }
    var title: String { rawValue }
}

/// Which folder inside the app a library is copied to.
enum InjectionFolder: String, CaseIterable, Identifiable, Codable {
    case frameworks = "Frameworks"
    case root = "/"

    var id: String { rawValue }
    var title: String { self == .frameworks ? L("/Frameworks/") : L("/") }
}

/// The app-wide configuration, kept in Application Support next to the tweaks
/// and injector libraries it points at.
final class AppConfigStore: ObservableObject {

    static let shared = AppConfigStore()

    @Published var config: AppConfig {
        didSet { if config != oldValue { save() } }
    }
    /// Injector libraries the user added, one per framework.
    @Published private(set) var injectors: [TweakInjector] = []
    /// What a framework's download is doing, per kind: shown beside its row.
    @Published private(set) var injectorStatus: [TweakInjectorKind: String] = [:]

    private static let defaultsKey = "appConfig.v3"
    private static let injectorsKey = "appConfig.injectors.v1"

    private init() {
        config = Self.loadConfig()
        injectors = Self.loadInjectors()
        Self.forgetMissingFiles(in: &config, injectors: &injectors)
    }

    // MARK: - Files

    /// Where tweak and injector copies live, so a picked file that came from a
    /// temporary location survives until the next install.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AppConfig", isDirectory: true)
    }

    static var tweaksDirectory: URL { supportDirectory.appendingPathComponent("Tweaks", isDirectory: true) }
    static var injectorsDirectory: URL { supportDirectory.appendingPathComponent("Injectors", isDirectory: true) }

    private static func copy(_ url: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    // MARK: - Tweaks

    /// Adds picked `.dylib` or `.deb` files. A `.deb` is read once here, so its
    /// package name and required injector can be shown before it's installed,
    /// and it replaces an earlier copy of the same package rather than sitting
    /// beside it: two builds of one tweak loaded together is never what anyone
    /// meant.
    ///
    /// `repository` is the repository a package came from, when the browser is
    /// the one adding it.
    @discardableResult
    func addTweaks(_ urls: [URL], repository: String? = nil) -> (added: Int, failed: [String]) {
        var added = 0
        var failed: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let lowered = name.lowercased()
            guard lowered.hasSuffix(".dylib") || lowered.hasSuffix(".deb") else {
                failed.append(name)
                continue
            }
            do {
                let stored = try Self.copy(url, into: Self.tweaksDirectory)
                if lowered.hasSuffix(".deb") {
                    let package = try DebArchive.read(stored)
                    // The package's own dependency first; failing that, what its
                    // libraries link against.
                    let linked = package.libraries.flatMap {
                        MachOInject.linkedLibraries(in: $0.data)
                    }
                    // The build it replaces, so its "load only if present"
                    // choice and its repository survive the swap.
                    let previous = package.identifier.flatMap { identifier in
                        config.tweaks.first { $0.identifier == identifier && $0.isDeb }
                    }
                    if let previous {
                        try? FileManager.default.removeItem(atPath: previous.path)
                        config.tweaks.removeAll { $0.id == previous.id }
                    }
                    config.tweaks.removeAll { $0.path == stored.path }
                    // The library the package actually carries, which is what
                    // the executable has to be told to load — a package's file
                    // name and its library's name rarely match.
                    let libraryName = package.libraries.first?.fileName
                        ?? (name as NSString).deletingPathExtension
                    config.tweaks.append(Tweak(name: package.name ?? name,
                                               path: stored.path,
                                               kind: .deb,
                                               loadPath: config.injectionPath(for: libraryName),
                                               weak: previous?.weak ?? true,
                                               requiresInjector: package.requiredInjector
                                                   ?? TweakInjectorKind.detected(inLibraries: linked),
                                               identifier: package.identifier,
                                               version: package.version,
                                               repository: repository ?? previous?.repository))
                } else {
                    // A bare library has no control file, so its links are the
                    // only clue to what it needs.
                    let linked = (try? Data(contentsOf: stored, options: .uncached))
                        .map { MachOInject.linkedLibraries(in: $0) } ?? []
                    config.tweaks.removeAll { $0.path == stored.path }
                    config.tweaks.append(Tweak(name: name, path: stored.path, kind: .dylib,
                                               loadPath: config.injectionPath(for: name),
                                               weak: true,
                                               requiresInjector: TweakInjectorKind.detected(inLibraries: linked)))
                }
                added += 1
            } catch {
                failed.append(name)
            }
        }
        // A tweak without its loader doesn't launch. Whatever the packages just
        // added depend on is fetched now rather than waiting for someone to
        // notice the warning — where a published build exists at all.
        fetchMissingInjectors()
        return (added, failed)
    }

    /// Downloads the frameworks the configured tweaks need, for the ones that
    /// have somewhere to download from. Closed-source loaders still have to be
    /// added by hand, and the panel says so.
    private func fetchMissingInjectors() {
        let wanted = missingInjectors.filter { InjectorCatalog.entry(for: $0).source != nil }
        guard !wanted.isEmpty else { return }
        Task { @MainActor in
            for kind in wanted where injector(for: kind) == nil {
                await downloadInjector(kind)
            }
        }
    }

    func isPinned(_ field: AppConfig.IdentityField) -> Bool { config.isPinned(field) }

    func pin(_ field: AppConfig.IdentityField, _ pinned: Bool) {
        config.setPinned(field, pinned)
    }

    func removeTweak(_ id: UUID) {
        guard let index = config.tweaks.firstIndex(where: { $0.id == id }) else { return }
        let tweak = config.tweaks.remove(at: index)
        try? FileManager.default.removeItem(atPath: tweak.path)
    }

    func setLoadPath(_ path: String, for id: UUID) {
        guard let index = config.tweaks.firstIndex(where: { $0.id == id }) else { return }
        config.tweaks[index].loadPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Changes how libraries are named, and rewrites the ones already added so
    /// the list and the load commands stay in step.
    func setInjectionBase(_ base: InjectionBase) {
        config.injectionBase = base
        rewriteLoadPaths()
    }

    func setInjectionFolder(_ folder: InjectionFolder) {
        config.injectionFolder = folder
        rewriteLoadPaths()
    }

    private func rewriteLoadPaths() {
        for index in config.tweaks.indices {
            let library = (config.tweaks[index].loadPath as NSString).lastPathComponent
            let fallback = (config.tweaks[index].path as NSString).deletingPathExtension
            config.tweaks[index].loadPath = config.injectionPath(for: library.isEmpty ? fallback : library)
        }
    }

    /// Records the injector a package expects, for libraries whose dependency
    /// can't be read from the file: an undefined `MSHookMessageEx` names no
    /// package, so the caller knows and the link list doesn't.
    func setRequiresInjector(_ kind: TweakInjectorKind?, forFileName fileName: String) {
        guard let index = config.tweaks.firstIndex(where: {
            ($0.path as NSString).lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame
        }) else { return }
        config.tweaks[index].requiresInjector = kind
    }

    func setWeak(_ weak: Bool, for id: UUID) {
        guard let index = config.tweaks.firstIndex(where: { $0.id == id }) else { return }
        config.tweaks[index].weak = weak
    }

    /// What a `.deb` carries, for the row's subtitle.
    func packageInfo(for tweak: Tweak) -> DebArchive.Package? {
        guard tweak.isDeb else { return nil }
        return try? DebArchive.read(URL(fileURLWithPath: tweak.path))
    }

    // MARK: - Injectors

    /// Adds the library that provides `kind`, replacing any previous one.
    @discardableResult
    func addInjector(_ kind: TweakInjectorKind, from url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dylib",
              let stored = try? Self.copy(url, into: Self.injectorsDirectory)
        else { return false }
        injectors.removeAll { $0.kind == kind }
        injectors.append(TweakInjector(kind: kind, path: stored.path,
                                       fileName: stored.lastPathComponent))
        saveInjectors()
        return true
    }

    /// Fetches a framework from where it's published (see `InjectorCatalog`),
    /// with its progress and any failure shown on its row.
    func downloadInjector(_ kind: TweakInjectorKind) async {
        injectorStatus[kind] = L("Downloading…")
        do {
            let fetched = try await InjectorCatalog.fetch(kind)
            if addInjectorData(fetched.data, kind: kind, fileName: fetched.fileName) {
                injectorStatus[kind] = L("Added %@", fetched.fileName)
            } else {
                injectorStatus[kind] = L("Couldn't store it.")
            }
        } catch {
            injectorStatus[kind] = (error as? LocalizedError)?.errorDescription
                ?? L("Download failed.")
        }
    }

    /// Stores library bytes as the framework for `kind`.
    @discardableResult
    func addInjectorData(_ data: Data, kind: TweakInjectorKind, fileName: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: Self.injectorsDirectory,
                                                    withIntermediateDirectories: true)
            let destination = Self.injectorsDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try data.write(to: destination, options: .atomic)
            injectors.removeAll { $0.kind == kind }
            injectors.append(TweakInjector(kind: kind, path: destination.path, fileName: fileName))
            saveInjectors()
            return true
        } catch {
            injectorStatus[kind] = L("Couldn't store it: %@", error.localizedDescription)
            return false
        }
    }

    /// Drops a framework's last download message when its row changes state.
    func clearInjectorStatus(_ kind: TweakInjectorKind) {
        injectorStatus[kind] = nil
    }

    func removeInjector(_ kind: TweakInjectorKind) {
        guard let index = injectors.firstIndex(where: { $0.kind == kind }) else { return }
        let injector = injectors.remove(at: index)
        try? FileManager.default.removeItem(atPath: injector.path)
        saveInjectors()
    }

    func injector(for kind: TweakInjectorKind) -> TweakInjector? {
        injectors.first { $0.kind == kind }
    }

    /// The injectors the configured tweaks need but that aren't here yet.
    var missingInjectors: [TweakInjectorKind] {
        let needed = Set(config.tweaks.compactMap { $0.requiresInjector })
        return needed.filter { injector(for: $0) == nil }.sorted { $0.title < $1.title }
    }

    // MARK: - Whole configuration

    /// The configuration as JSON, for keeping or sharing.
    func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(config)
    }

    /// Replaces the configuration from a JSON file. Tweaks and injectors keep
    /// their paths, so an imported file only works for packages that are here.
    @discardableResult
    func importData(_ data: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode(AppConfig.self, from: data),
              decoded.schema == 3 else { return false }
        config = decoded
        Self.forgetMissingFiles(in: &config, injectors: &injectors)
        return true
    }

    /// Seeds the configuration from a build's own settings, so the signing
    /// panel starts from what the app is rather than from empty fields.
    ///
    /// Only what the panel can express is taken: the identity it declares, and
    /// the capabilities its plist and entitlements already grant. The build's
    /// whole `Info.plist` would be hundreds of keys, and its entitlements are
    /// re-issued by the profile Apple signs with, so copying them back would be
    /// writing down a copy of a document that gets replaced.
    func adopt(info: [String: Any], entitlements: [String: Any]) {
        config.displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String) ?? ""
        config.bundleIdentifier = info["CFBundleIdentifier"] as? String ?? ""
        config.version = info["CFBundleShortVersionString"] as? String ?? ""
        config.build = info["CFBundleVersion"] as? String ?? ""

        // Capabilities are not copied into edits: doing so would replace the
        // build’s existing arrays and entitlements on an otherwise unchanged install.

    }

    /// Forgets what a run was given, once the run is over: identity, plist and
    /// entitlement edits, capabilities, and the tweak copies it injected.
    ///
    /// The next install starts from its own build. Injectors stay — they're
    /// frameworks, not part of any one app — and tweaks kept in Tweak storage
    /// are untouched, so a set can be applied again in one tap.
    func clearAfterInstall() {
        guard config.isActive || !config.tweaks.isEmpty else { return }
        reset()
    }

    func reset() {
        let tweaks = config.tweaks
        config = AppConfig()
        for tweak in tweaks { try? FileManager.default.removeItem(atPath: tweak.path) }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func saveInjectors() {
        guard let data = try? JSONEncoder().encode(injectors) else { return }
        UserDefaults.standard.set(data, forKey: Self.injectorsKey)
    }

    private static func loadConfig() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data),
              config.schema == 3
        else { return AppConfig() }
        return config
    }

    private static func loadInjectors() -> [TweakInjector] {
        guard let data = UserDefaults.standard.data(forKey: injectorsKey),
              let injectors = try? JSONDecoder().decode([TweakInjector].self, from: data)
        else { return [] }
        return injectors
    }

    /// A tweak or injector whose file has been deleted (by iOS, or by the user
    /// in Files) can't be used, so it's dropped rather than failing the install.
    private static func forgetMissingFiles(in config: inout AppConfig,
                                           injectors: inout [TweakInjector]) {
        config.tweaks.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        injectors.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
    }
}
