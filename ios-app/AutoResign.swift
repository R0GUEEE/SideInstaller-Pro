import BackgroundTasks
import Foundation
import UserNotifications

/// Renewing apps before their profile runs out.
///
/// A free Apple ID's provisioning profile lasts seven days; when it lapses the
/// app stops launching. SideInstaller already knows how to re-sign and reinstall
/// an app over itself, so this runs that pass from a background wake-up while
/// there's still time — and says so afterwards, whether it worked or not.
///
/// What it can't do is magic: re-signing needs a live Apple session, so a wake-up
/// that finds the account signed out doesn't renew anything. It reports that
/// instead of failing silently, and the pass is skipped entirely when nothing is
/// close to expiring.
@MainActor
final class AutoResign: ObservableObject {

    static let shared = AutoResign()

    /// The identifier must appear in Info.plist's BGTaskSchedulerPermittedIdentifiers.
    static let taskIdentifier = "com.frizzlem.sideinstaller.refresh"

    /// How close to expiry an app has to be before it's renewed.
    static let defaultHoursBefore = 24

    @Published private(set) var isRunning = false
    /// What the last pass did, for the Settings row.
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastSummary: String?

    private init() {}

    // MARK: - Scheduling

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

    /// Asks for the next wake-up. Called at launch and after every pass, so a
    /// skipped wake-up doesn't stop the chain.
    func schedule() {
        guard AppSettings.shared.autoResignEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        // Twice a day is plenty: the threshold is measured in hours, not
        // minutes, and iOS would throttle a tighter loop anyway.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Engine.shared.log("Auto re-sign couldn't be scheduled: \(error.localizedDescription)")
        }
    }

    private func handle(_ task: BGAppRefreshTask) async {
        guard AppSettings.shared.autoResignEnabled else {
            task.setTaskCompleted(success: true)
            return
        }
        schedule()
        let work = Task { @MainActor in
            await run(interactive: false)
        }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
    }

    // MARK: - The pass

    /// Re-signs every sideloaded app whose profile expires within the threshold.
    ///
    /// `interactive` is true when a person asked for it: that pass may open the
    /// device link and sign in, where a background one uses what's already there.
    @discardableResult
    func run(interactive: Bool) async -> String {
        guard !isRunning else { return L("A renewal pass is already running.") }
        isRunning = true
        defer { isRunning = false }

        let threshold = Double(AppSettings.shared.autoResignHoursBefore) * 3_600
        guard let cached = SideloadedAppsManager.cachedInventory() else {
            let message = L("No app list yet — open My Apps once, then this can keep them renewed.")
            finish(message)
            return message
        }
        let apps = cached.apps.compactMap { SideloadedApp(plist: $0, kinds: [.sideloaded]) }
        let profiles = cached.profiles.compactMap(ProvisioningProfile.init(data:))
        let matched = ProfileMatcher.match(apps: apps, profiles: profiles)

        let cutoff = Date().addingTimeInterval(threshold)
        let expiring = matched.entries.filter { status in
            guard let expiry = status.current?.expirationDate else { return false }
            return expiry <= cutoff
        }
        guard !expiring.isEmpty else {
            let message = L("Nothing is within %ld hours of expiring.", AppSettings.shared.autoResignHoursBefore)
            finish(message)
            return message
        }

        // Signing in is the expensive, prompt-prone part; it belongs once
        // before the loop, not once per app.
        do {
            try await Engine.shared.prepareRefresh(interactive: interactive)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? L("Couldn't sign in. Open SideInstaller to finish it.")
            finish(message)
            notify(title: L("App renewal"), body: message)
            return message
        }

        // Only apps whose .ipa is still on the device can be renewed here.
        let library = IPALibrary.installable()
        var renewed: [String] = []
        var failed: [String] = []
        for status in expiring {
            if Task.isCancelled || (!interactive && !AppSettings.shared.autoResignEnabled) { break }
            guard let match = library.first(where: {
                ProfileMatcher.installed(status.app.bundleID, isBuiltFrom: $0.info.bundleID,
                                         teamID: status.current?.teamIdentifier)
            }) else {
                failed.append(status.app.name)
                continue
            }
            do {
                try await Engine.shared.refreshInstalledApp(named: status.app.name,
                                                            ipaPath: match.entry.url.path)
                renewed.append(status.app.name)
            } catch {
                failed.append(status.app.name)
                Engine.shared.log("Auto re-sign: \(status.app.name) failed — \(error.localizedDescription)")
            }
        }

        let message: String
        switch (renewed.count, failed.count) {
        case let (done, 0) where done > 0:
            message = L("Renewed %ld app(s).", done)
        case (0, let trouble):
            message = L("Couldn't renew %ld app(s). Open My Apps and re-sign them.", trouble)
        default:
            message = L("Renewed %ld app(s); %ld couldn't be.", renewed.count, failed.count)
        }
        finish(message)
        if !renewed.isEmpty || !failed.isEmpty {
            notify(title: L("App renewal"), body: message)
        }
        return message
    }

    private func finish(_ message: String) {
        lastRun = Date()
        lastSummary = message
        Engine.shared.log("Auto re-sign: \(message)")
    }

    /// A summary of what would be renewed, for the Settings row.
    func pendingDescription() -> String {
        guard let cached = SideloadedAppsManager.cachedInventory() else {
            return L("No app list yet. Open My Apps once.")
        }
        let apps = cached.apps.compactMap { SideloadedApp(plist: $0, kinds: [.sideloaded]) }
        let profiles = cached.profiles.compactMap(ProvisioningProfile.init(data:))
        let matched = ProfileMatcher.match(apps: apps, profiles: profiles)
        let cutoff = Date().addingTimeInterval(Double(AppSettings.shared.autoResignHoursBefore) * 3_600)
        let count = matched.entries.filter { status in
            guard let expiry = status.current?.expirationDate else { return false }
            return expiry <= cutoff
        }.count
        return count == 0
            ? L("Nothing expires in the next %ld hours.", AppSettings.shared.autoResignHoursBefore)
            : (count == 1 ? L("1 app expires within %ld hours.", AppSettings.shared.autoResignHoursBefore)
                          : L("%ld apps expire within %ld hours.", count, AppSettings.shared.autoResignHoursBefore))
    }

    // MARK: - Notifications

    /// Asked for when the feature is switched on, not at launch.
    static func requestAuthorization() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        let granted = (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
        return granted
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "auto-resign-\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Settings

extension AppSettings {
    /// Renew apps before their profile lapses.
    var autoResignEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "appSettings.autoResignEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "appSettings.autoResignEnabled")
            objectWillChange.send()
            if newValue {
                Task { @MainActor in
                    AutoResign.shared.schedule()
                    _ = await AutoResign.requestAuthorization()
                }
            } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AutoResign.taskIdentifier)
            }
        }
    }

    /// How many hours before expiry a renewal happens.
    var autoResignHoursBefore: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "appSettings.autoResignHours")
            return value == 0 ? AutoResign.defaultHoursBefore : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "appSettings.autoResignHours")
            objectWillChange.send()
        }
    }
}

