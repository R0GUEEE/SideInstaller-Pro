import AVFAudio
import CoreLocation
import Foundation
import SwiftUI

/// How the app asks iOS to keep it running while it isn't on screen.
enum KeepAliveMode: String, CaseIterable, Identifiable {
    case off
    case audio
    case location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:      return L("Off")
        case .audio:    return L("Silent audio")
        case .location: return L("Location updates")
        }
    }

    var detail: String {
        switch self {
        case .off:
            return L("iOS suspends the app when it leaves the screen. Work already handed off still finishes.")
        case .audio:
            return L("Plays silence through a playback session, which iOS treats as ongoing audio. The most reliable of the two, and the one that keeps a tunnel, a queue or a serving socket answering.")
        case .location:
            return L("Runs a low-accuracy location session. Cheaper on the battery than a song, but iOS stops it if you take away location permission.")
        }
    }

    var icon: String {
        switch self {
        case .off:      return "pause.circle"
        case .audio:    return "waveform"
        case .location: return "location.circle"
        }
    }
}

/// A keep-alive the user turns on deliberately: silent audio or a location
/// session, the two background modes this app declares in its Info.plist.
///
/// It exists because the alternative is worse — a run killed mid-install, or a
/// local source that stops answering the moment the screen locks. It is also
/// exactly what it looks like: while it's on, the app is asking iOS to keep it
/// alive, and the battery pays for it.
@MainActor
final class BackgroundKeeper: NSObject, ObservableObject {

    static let shared = BackgroundKeeper()

    /// What's running. `.off` means nothing is.
    @Published private(set) var mode: KeepAliveMode = .off
    /// When the current keep-alive started, for the status line.
    @Published private(set) var startedAt: Date?
    /// Why the last start failed, if it did.
    @Published private(set) var lastError: String?

    var isRunning: Bool { mode != .off }

    private static let defaultsKey = "backgroundKeeper.mode"

    // MARK: Audio

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    // MARK: Location

    private let location = CLLocationManager()
    /// True while a permission prompt is up for the location keep-alive: the
    /// session starts in the delegate, so `start` mustn't announce success yet.
    private var pendingLocationStart = false

    private override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        location.allowsBackgroundLocationUpdates = true
    }

    // MARK: Control

    /// Starts the chosen keep-alive, replacing whatever was running.
    func start(_ newMode: KeepAliveMode) {
        stop()
        lastError = nil
        guard newMode != .off else {
            UserDefaults.standard.set(KeepAliveMode.off.rawValue, forKey: Self.defaultsKey)
            return
        }
        switch newMode {
        case .off:
            break
        case .audio:
            startAudio()
        case .location:
            startLocation()
        }
        // A prompt is up: the delegate finishes the job when it's answered.
        if newMode == .location, pendingLocationStart { return }
        guard lastError == nil else { return }
        mode = newMode
        startedAt = Date()
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.defaultsKey)
    }

    func stop() {
        guard mode != .off || startedAt != nil else {
            // Nothing running: still worth clearing a stale preference.
            UserDefaults.standard.set(KeepAliveMode.off.rawValue, forKey: Self.defaultsKey)
            return
        }
        pendingLocationStart = false
        stopAudio()
        stopLocation()
        mode = .off
        startedAt = nil
        UserDefaults.standard.set(KeepAliveMode.off.rawValue, forKey: Self.defaultsKey)
    }

    /// Restarts whatever was on when the app was last used. Called once at
    /// launch, after the app is up.
    func restore() {
        guard let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
              let saved = KeepAliveMode(rawValue: raw), saved != .off else { return }
        // Audio resumes silently at launch. Location would put a permission
        // prompt in front of someone who just opened the app, so it waits until
        // the page is used — unless it's already allowed.
        if saved == .location {
            let status = location.authorizationStatus
            guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        }
        start(saved)
    }

    // MARK: Audio

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let format = engine.outputNode.inputFormat(forBus: 0)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)

            let frames = AVAudioFrameCount(format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw KeepAliveError.noBuffer
            }
            buffer.frameLength = frames

            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
        } catch {
            lastError = L("Couldn't start the audio session: %@", error.localizedDescription)
            stopAudio()
        }
    }

    private func stopAudio() {
        guard engine.isRunning else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: Location

    private func startLocation() {
        let status = location.authorizationStatus
        if status == .notDetermined {
            pendingLocationStart = true
            location.requestAlwaysAuthorization()
            // The session starts in the delegate once the answer arrives.
            return
        }
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            lastError = L("Location access is off for SideInstaller. Allow it in Settings › Privacy › Location Services, or use silent audio instead.")
            return
        }
        location.startUpdatingLocation()
    }

    private func stopLocation() {
        location.stopUpdatingLocation()
    }

    enum KeepAliveError: LocalizedError {
        case noBuffer

        var errorDescription: String? { L("The audio buffer couldn't be allocated.") }
    }
}

extension BackgroundKeeper: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard pendingLocationStart, mode == .off else { return }
            // A prompt answered while the location keep-alive was pending.
            let status = manager.authorizationStatus
            guard status == .authorizedAlways || status == .authorizedWhenInUse else {
                if status != .notDetermined {
                    pendingLocationStart = false
                    lastError = L("Location access was declined, so the keep-alive didn't start.")
                }
                return
            }
            pendingLocationStart = false
            manager.startUpdatingLocation()
            mode = .location
            startedAt = Date()
            UserDefaults.standard.set(KeepAliveMode.location.rawValue, forKey: Self.defaultsKey)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            lastError = L("Location stopped: %@", error.localizedDescription)
        }
    }
}

// MARK: - The page

/// **Tools › Background**: the keep-alive switch, and the honest description of
/// what each mode costs.
struct BackgroundKeeperView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var keeper = BackgroundKeeper.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                BrandHeader(icon: "clock.badge.checkmark", title: L("Background")) {
                    StatusPill(text: keeper.isRunning
                               ? L("Running · %@", keeper.mode.title)
                               : L("Suspended"),
                               systemImage: keeper.isRunning ? "checkmark.circle.fill" : "pause.circle.fill",
                               color: keeper.isRunning ? .green : .secondary)
                }
                .cascadeItem(0)

                modeCard.cascadeItem(1)
                if keeper.isRunning { statusCard.cascadeItem(2) }
                explanation.cascadeItem(3)
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
    }

    private var modeCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Keep the app running"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(KeepAliveMode.allCases) { option in
                    Button {
                        Haptics.tap()
                        if option == .off { keeper.stop() } else { keeper.start(option) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: keeper.mode == option
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.footnote)
                                .foregroundStyle(keeper.mode == option
                                                 ? AnyShapeStyle(Theme.accent2)
                                                 : AnyShapeStyle(.tertiary))
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(option.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if option != KeepAliveMode.allCases.last {
                        Divider().opacity(0.12).padding(.leading, 26)
                    }
                }
                if let error = keeper.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("Running"), systemImage: keeper.mode.icon)
                    .font(.subheadline.weight(.semibold))
                if let since = keeper.startedAt {
                    Text(L("Since %@.", since.formatted(date: .omitted, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L("The app keeps running while it's in the background, so a run that's already started can finish and the local source keeps answering."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Stop"), role: .destructive) {
                    keeper.stop()
                    Haptics.destructive()
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("What iOS actually allows"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(L("A sideloaded app is suspended when it leaves the screen unless it has a reason to stay. Silent audio and location are the two reasons SideInstaller can claim, and both are a background mode it declares — iOS shows a location arrow while the second is on."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Neither is unlimited. Audio stops if another app takes the audio session and iOS may still throttle a session that never makes a sound; location stops without permission and costs battery. Nothing here survives the app being force-quit."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("The setting is remembered: whichever mode is on comes back the next time the app launches."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
