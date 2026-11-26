import Foundation

/// The in-app-purchase patches bundled with the app, and the one switch that
/// adds all of them to a build.
///
/// Three libraries, three attacks on the same wall:
///
/// - **SatellaJailed** hooks StoreKit's own receipt and transaction paths with
///   its own Swift hook runtime (it links only system frameworks — no
///   Substrate), so a local receipt check sees a valid purchase.
/// - **iOSGods iAPCracker** is a Logos tweak: it swivels
///   `SKPaymentTransaction.transactionState` to `.purchased` through
///   `MSHookMessageEx`, which an injection framework supplies, not the library.
/// - **autoRevenuecat** hooks RevenueCat's `RCPurchaserInfo` and its
///   entitlement mapping, for apps whose purchases are decided by RevenueCat
///   rather than by StoreKit directly.
///
/// Each covers apps the others don't, so they're added together. Injection order
/// doesn't matter: none of them call each other.
enum IAPTweaks {

    struct Entry {
        /// The name the library gets inside the app's `Frameworks` folder.
        let fileName: String
        /// What it does, in one line, for the toggle's caption.
        let method: String
        /// Set when the library expects an injection framework to supply a
        /// symbol it calls. Only the Logos tweak does.
        let needsInjector: Bool
    }

    static let entries: [Entry] = [
        Entry(fileName: "SatellaJailed.dylib",
              method: L("Hooks StoreKit's receipt and transaction checks through its own runtime"),
              needsInjector: false),
        Entry(fileName: "iOSGodsiAPCracker.dylib",
              method: L("Reports every SKPaymentTransaction as purchased (needs MSHookMessageEx)"),
              needsInjector: true),
        Entry(fileName: "autoRevenuecat-v3.2.dylib",
              method: L("Answers RevenueCat as if every entitlement is active"),
              needsInjector: false),
    ]

    /// True when every one of them is in the configuration.
    static func isEnabled(in store: AppConfigStore) -> Bool {
        entries.allSatisfy { contains($0, in: store) }
    }

    /// The injector the Logos tweak needs, preferring what's already on this
    /// iPhone: substrate, substitute, libhooker and ElleKit all export the
    /// symbol it calls.
    static func requiredInjector(in store: AppConfigStore) -> TweakInjectorKind? {
        guard entries.contains(where: \.needsInjector) else { return nil }
        let preference: [TweakInjectorKind] = [.ellekit, .substitute, .substrate, .libhooker]
        return preference.first { store.injector(for: $0) != nil } ?? .ellekit
    }

    /// Adds or removes the three libraries. Returns a line for the panel, or nil
    /// when there was nothing to do.
    @MainActor
    @discardableResult
    static func setEnabled(_ enabled: Bool, in store: AppConfigStore) -> String? {
        if enabled {
            var added = 0
            var missing: [String] = []
            for entry in entries where !contains(entry, in: store) {
                guard let data = data(for: entry.fileName) else {
                    missing.append(entry.fileName)
                    continue
                }
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent(entry.fileName)
                try? FileManager.default.removeItem(at: staging)
                do {
                    try data.write(to: staging, options: .atomic)
                    if store.addTweaks([staging]).added == 1 { added += 1 }
                } catch {
                    missing.append(entry.fileName)
                }
                try? FileManager.default.removeItem(at: staging)
            }
            // The Logos tweak can't be recognised from its links — the symbol it
            // needs was left undefined at build time — so it's marked here.
            let injector = requiredInjector(in: store)
            for entry in entries where entry.needsInjector {
                store.setRequiresInjector(injector, forFileName: entry.fileName)
            }
            if !missing.isEmpty {
                return L("Added %d of %d — %@ wasn't bundled with this build.",
                         added, entries.count, missing.joined(separator: ", "))
            }
            return added > 0
                ? L("Added %d in-app-purchase tweak(s).", added)
                : L("The in-app-purchase tweaks were already in the configuration.")
        }

        let removed = store.config.tweaks.filter { tweak in
            entries.contains {
                (tweak.path as NSString).lastPathComponent.caseInsensitiveCompare($0.fileName) == .orderedSame
            }
        }
        for tweak in removed { store.removeTweak(tweak.id) }
        return removed.isEmpty ? nil : L("Removed %d in-app-purchase tweak(s).", removed.count)
    }

    private static func contains(_ entry: Entry, in store: AppConfigStore) -> Bool {
        store.config.tweaks.contains { tweak in
            (tweak.path as NSString).lastPathComponent.caseInsensitiveCompare(entry.fileName) == .orderedSame
        }
    }

    /// A library's bytes, decoded from its base64 copy in the bundle.
    ///
    /// The three are stored encoded, not as Mach-O: a raw `.dylib` in Resources
    /// is unsigned nested code, and codesign refuses to sign the app around it.
    /// Decoding costs a moment when the switch is turned on.
    static func data(for fileName: String) -> Data? {
        guard let url = bundled(fileName + ".b64"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let stripped = text.filter { !$0.isWhitespace }
        return Data(base64Encoded: stripped)
    }

    /// Where a bundled resource is. A folder reference in the project can land
    /// in the bundle root or under `Resources/`, so every place it might be is
    /// tried.
    static func bundled(_ fileName: String) -> URL? {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: fileName, withExtension: nil),
            bundle.bundleURL.appendingPathComponent(fileName),
            bundle.bundleURL.appendingPathComponent("IAPTweaks/\(fileName)"),
            bundle.resourceURL?.appendingPathComponent(fileName),
            bundle.resourceURL?.appendingPathComponent("IAPTweaks/\(fileName)"),
            bundle.bundleURL.appendingPathComponent("Resources/IAPTweaks/\(fileName)"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
