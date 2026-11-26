import Combine
import Foundation

/// Saved App-configurations, applied in one tap.
///
/// The configuration page is where the real decisions live (bundle ID, stripped
/// extensions, tweaks, entitlements), and re-making one for every build is
/// tedious. A preset is that whole configuration under a name.
@MainActor
final class InstallPresets: ObservableObject {

    static let shared = InstallPresets()

    struct Preset: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var config: AppConfig
        var savedAt: Date

        /// A one-line summary for the list: what applying it would do.
        var summary: String {
            var parts: [String] = []
            if !config.bundleIdentifier.trimmed.isEmpty { parts.append(config.bundleIdentifier) }
            if config.stripExtensions { parts.append(L("no extensions")) }
            if config.stripWatchApp { parts.append(L("no watch app")) }
            if !config.tweaks.isEmpty { parts.append(L("\(config.tweaks.count) tweak(s)")) }
            if !config.plistEdits.isEmpty { parts.append(L("\(config.plistEdits.count) plist edit(s)")) }
            if !config.entitlements.isEmpty { parts.append(L("\(config.entitlements.count) entitlement(s)")) }
            return parts.isEmpty ? L("Nothing changed") : parts.joined(separator: " · ")
        }
    }

    @Published private(set) var presets: [Preset] = []

    private static let defaultsKey = "install.presets.v1"

    private init() {
        presets = Self.load()
    }

    /// Saves the current configuration under `name`, replacing a preset of the
    /// same name.
    @discardableResult
    func save(_ name: String, config: AppConfig) -> Preset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var copy = config
        // A preset shouldn't carry a bundle ID: that's per-app, and applying one
        // app's ID to another build would be wrong every time.
        copy.bundleIdentifier = ""
        copy.displayName = ""
        let preset = Preset(id: presets.first { $0.name == trimmed }?.id ?? UUID(),
                            name: trimmed, config: copy, savedAt: Date())
        presets.removeAll { $0.name == trimmed }
        presets.insert(preset, at: 0)
        persist()
        return preset
    }

    func remove(_ id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    /// Applies a preset to the live configuration, keeping the bundle ID and
    /// display name the page already has for the build being installed.
    func apply(_ preset: Preset) {
        let store = AppConfigStore.shared
        var config = preset.config
        config.bundleIdentifier = store.config.bundleIdentifier
        config.displayName = store.config.displayName
        config.version = store.config.version
        config.build = store.config.build
        config.pinnedIdentity = store.config.pinnedIdentity
        store.config = config
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let presets = try? JSONDecoder().decode([Preset].self, from: data)
        else { return [] }
        return presets
    }
}
