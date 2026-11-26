import SwiftUI

@main
struct SideInstallerApp: App {
    // Held here so SwiftUI observes the same instance the C log callback targets.
    @StateObject private var engine = Engine.shared
    // Checks GitHub for a newer release and drives the update banner.
    @StateObject private var updateChecker = UpdateChecker()
    // Held here so every screen redraws when the language setting changes.
    @StateObject private var localizer = Localizer.shared
    // The saved Apple IDs, shared by every screen that signs in.
    @StateObject private var accounts = AccountStore.shared
    /// False until the TOS is accepted, after which the welcome page is gone.
    @AppStorage("hasAcceptedTOS") private var hasAcceptedTOS = false
    /// False until account setup is completed or skipped. Never reset, even if
    /// all accounts are removed later.
    @AppStorage("hasCompletedAccountSetup") private var hasCompletedAccountSetup = false

    init() {
        // Run before background services start: no live operation owns these leftovers.
        StorageMaintenance.atLaunch()
        // A pairing code still up from a run that was killed means nothing now.
        PairingLiveActivity.shared.endLeftovers()
        PairingNotification.shared.reset()
        // So is an install's progress.
        InstallActivity.shared.endLeftovers()
        // Background refreshes of the Telegram source, and the handler that
        // runs them. Registration has to happen before the app finishes
        // launching, so it's first.
        BackgroundKeepAlive.shared.register()
        BackgroundKeepAlive.shared.scheduleRefresh()
        // Whatever keep-alive was on when the app was last used, back on: a run
        // in progress shouldn't depend on the user remembering to flip it.
        BackgroundKeeper.shared.restore()
        // Renewing apps before their profile lapses.
        AutoResign.shared.register()
        AutoResign.shared.schedule()
        // Settings can start the local server and scan the channels with the
        // app, so both go through the objects the screens use.
        let settings = AppSettings.shared
        if settings.serverAutoStart { LocalSourceServer.shared.start() }
        if settings.scanOnLaunch {
            Task { @MainActor in await TelegramStudio.shared.scan() }
        }
        // iOS hands over the last crash's diagnostic now, for Report a problem.
        CrashDiagnostics.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if hasAcceptedTOS && hasCompletedAccountSetup {
                    RootView()
                        .environmentObject(engine)
                        .environmentObject(updateChecker)
                        .environmentObject(localizer)
                        .environmentObject(accounts)
                        .task { await updateChecker.check() }
                        .transition(.opacity)
                } else if hasAcceptedTOS {
                    AccountSetupView()
                        .environmentObject(localizer)
                        .environmentObject(accounts)
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .opacity.combined(with: .scale(scale: 1.06))))
                        // Layered between the welcome page and the app, so each
                        // zooms out over the next screen.
                        .zIndex(0.5)
                } else {
                    WelcomeView()
                        .environmentObject(localizer)
                        // Zoom past the camera while the app fades in beneath.
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .opacity.combined(with: .scale(scale: 1.06))))
                        .zIndex(1)
                }
            }
            .animation(.smooth(duration: 0.5), value: hasAcceptedTOS)
            .animation(.smooth(duration: 0.5), value: hasCompletedAccountSetup)
            // Files opened in the app (share sheet, "Open with", other apps), as
            // an alternative to the document picker, and `sideinstaller://`
            // links, which ask before doing anything.
            .onOpenURL { url in
                guard url.isFileURL else {
                    engine.receiveLink(url)
                    return
                }
                // `.mobiledevicepairing`/`.plist` are pairing files; anything else
                // is treated as an IPA.
                if ["mobiledevicepairing", "plist"].contains(url.pathExtension.lowercased()) {
                    Task { await engine.importPairingFile(from: url) }
                } else {
                    engine.installSource = .custom
                    Task { await engine.importCustomIPA(from: url) }
                }
            }
        }
    }
}

