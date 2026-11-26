import AppIntents
import Foundation

/// Shortcuts and Siri actions.
///
/// Each one is the same work the matching button does, exposed to the system:
/// scan the sources, re-sign everything, queue a link, or open the marketplace.
/// The intents run in the app's process, which is why they can call the same
/// main-actor objects the screens use.
/// What an intent throws when the value it was handed isn't one it can use.
/// App Intents shows a `LocalizedError`'s description to the user.
struct IntentInputError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@available(iOS 16.0, *)
struct ScanSourcesIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan sources"
    static var description = IntentDescription(
        "Fetch every source and rebuild the marketplace list.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = SourceStore.shared
        await MainActor.run { store.load() }
        await store.refreshAll(force: true)
        let count = await MainActor.run { store.entries.count }
        return .result(dialog: IntentDialog("\(count) apps across your sources."))
    }
}

@available(iOS 16.0, *)
struct ResignAllIntent: AppIntent {
    static var title: LocalizedStringResource = "Re-sign installed apps"
    static var description = IntentDescription(
        "Renew every sideloaded app whose build SideInstaller has stored.")

    @Parameter(title: "Only those expiring within (hours)", default: 24)
    var hours: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Re-sign apps expiring within \(\.$hours) hours")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await AutoResign.shared.run(interactive: true)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

@available(iOS 16.0, *)
struct QueueInstallIntent: AppIntent {
    static var title: LocalizedStringResource = "Add an .ipa to the install queue"
    static var description = IntentDescription(
        "Puts a download link in SideInstaller's queue; the install runs when the app opens.")

    @Parameter(title: "Link", description: "An https:// link to an .ipa file.")
    var link: URL

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let target = Engine.downloadLink(link.absoluteString) else {
            throw IntentInputError("That isn't a link to an .ipa file.")
        }
        let added = await InstallQueue.shared.add(name: target.lastPathComponent,
                                                  url: target)
        return .result(dialog: IntentDialog(added
            ? "Queued \(target.lastPathComponent)."
            : "That link is already queued."))
    }
}

@available(iOS 16.0, *)
struct OpenMyAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open My Apps"
    static var description = IntentDescription("Shows the apps installed with a profile, and when they expire.")
    /// Opening a screen is what the app is for; the intent just brings it up.
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { AppRouter.shared.go(.apps) }
        return .result()
    }
}

/// The phrases Siri and the Shortcuts app offer without any setup.
@available(iOS 16.0, *)
struct SideInstallerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScanSourcesIntent(),
                    phrases: ["Scan my sources in \(.applicationName)",
                              "Refresh \(.applicationName) sources"],
                    shortTitle: "Scan sources",
                    systemImageName: "arrow.clockwise")
        AppShortcut(intent: ResignAllIntent(),
                    phrases: ["Re-sign my apps in \(.applicationName)",
                              "Renew expiring apps with \(.applicationName)"],
                    shortTitle: "Re-sign apps",
                    systemImageName: "signature")
        AppShortcut(intent: OpenMyAppsIntent(),
                    phrases: ["Show my apps in \(.applicationName)"],
                    shortTitle: "My Apps",
                    systemImageName: "square.stack.3d.up")
    }
}
