import BackgroundTasks
import Foundation
import UIKit

/// Keeping the local source server answering while SideInstaller is in the background.
///
/// **What this does** — two things iOS actually offers an app:
///
/// 1. `beginBackgroundTask` — about thirty seconds after the app is backgrounded,
///    during which the socket stays open and a client can finish fetching.
/// 2. `BGAppRefreshTask` — a wake-up iOS schedules on its own terms (minutes to
///    hours, based on how the app is used) during which the app can rescan and
///    keep the source current without being opened.
///
/// **What it doesn't do** — the two tricks that *would* keep a socket alive
/// indefinitely: playing silent audio with the `audio` background mode, or
/// holding a location session with `location`. Both are background-mode abuse:
/// they misdeclare what the app does, they drain the battery, and on a sideloaded
/// build they're the kind of thing that gets a signing certificate pulled. They
/// also don't reliably work — iOS still throttles a silent-audio app that never
/// plays anything audible. So the honest ceiling is "a few seconds after
/// backgrounding, plus periodic refreshes", and that's what this implements.
@MainActor
final class BackgroundKeepAlive: ObservableObject {

    static let shared = BackgroundKeepAlive()

    /// The identifier must appear in Info.plist's BGTaskSchedulerPermittedIdentifiers.
    static let taskIdentifier = "com.frizzlem.sideinstaller.telegram"

    @Published private(set) var isExtending = false
    /// When the last background refresh ran, for the card's status line.
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastRefreshApps: Int?

    private var task: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    /// Registers for background refreshes. Call once, at launch.
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier,
                                        using: .main) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await self?.handle(refresh)
            }
        }
    }

    /// Asks for the next refresh — a few hours at most, whenever iOS decides.
    func scheduleRefresh() {
        guard AppSettings.shared.backgroundRefresh else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Engine.shared.log("Background refresh couldn't be scheduled: \(error.localizedDescription)")
        }
    }

    /// Holds the app awake for a short while after it's backgrounded, so the
    /// local server can finish what a client asked for.
    func extendForBackground() {
        guard task == .invalid else { return }
        isExtending = true
        task = UIApplication.shared.beginBackgroundTask(withName: "source-server") { [weak self] in
            Task { @MainActor in self?.endExtension() }
        }
        Engine.shared.log("Holding the app for a background grace period…")
    }

    func endExtension() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
        isExtending = false
    }

    // MARK: - The refresh itself

    private func handle(_ task: BGAppRefreshTask) async {
        // Line up the next one before doing any work: a refresh that ends early
        // would otherwise stop the chain.
        scheduleRefresh()
        let studio = TelegramStudio.shared
        let done = Task { @MainActor in
            await studio.scan()
            lastRefresh = Date()
            lastRefreshApps = studio.allEntries.count
            if studio.allEntries.isEmpty == false { studio.generateSource() }
        }
        task.expirationHandler = {
            done.cancel()
        }
        await done.value
        task.setTaskCompleted(success: !done.isCancelled)
        Engine.shared.log("Background refresh finished: \(studio.allEntries.count) app(s).")
    }
}
