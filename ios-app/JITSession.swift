import Foundation
import UIKit

/// Turning JIT on for an app the way a debugger does.
///
/// iOS refuses `mmap(PROT_EXEC)` for pages the app didn't come with — that's
/// what a JIT-less device means. The one way through is the debugger: a process
/// that a debugger has attached to has `CS_DEBUGGED` set, and such a process is
/// allowed to map executable memory. So the sequence is the one Xcode and
/// StikDebug use:
///
/// 1. launch the app *suspended*, through DVT process control;
/// 2. attach the device's debugger to the stopped process (`vAttach`);
/// 3. let it run (`c`), leaving the connection open;
/// 4. hold the session open for as long as the app should keep JIT.
///
/// When the session closes — or the debugger detaches — the next executable
/// mapping fails and the app falls back to its interpreter.
@MainActor
final class JITSession: ObservableObject {

    static let shared = JITSession()

    enum State: Equatable {
        case idle
        case launching
        case attaching
        case running(pid: UInt32)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The app the session is holding open, for the My Apps row to show.
    @Published private(set) var bundleID: String?

    /// The proxy the session speaks to: kept alive on purpose.
    private var proxy: OpaquePointer?
    private var pid: UInt64 = 0
    private var log: [String] = []

    var isActive: Bool {
        if case .running = state { return true }
        return false
    }

    /// Launch `bundleID` with JIT enabled and keep it that way until the app
    /// exits or `stop()` is called.
    ///
    /// The app is launched suspended on purpose, so nothing it does at startup
    /// runs before the debugger is attached — anything that tried to map
    /// executable memory in that window would fail, and some JIT runtimes cache
    /// that failure.
    func enable(bundleID: String, name: String) async {
        guard !isActive else { return }
        let engine = Engine.shared
        state = .launching
        self.bundleID = bundleID
        log = []
        do {
            try await engine.prepareDeviceLink()
            let device = engine.connection

            // 1. Stopped at the entry point.
            let launched = try await engine.onDeviceQueue {
                try device.launchDebugProcess(bundleID: bundleID)
            }
            pid = launched.pid
            note("Launched \(name) suspended (pid \(launched.pid)).")
            state = .attaching

            // 2. Attach: this is what grants CS_DEBUGGED, the permission to map
            //    executable pages.
            let handle = try await engine.onDeviceQueue { try device.debugProxy() }
            proxy = handle
            let attach = try await engine.onDeviceQueue {
                try device.sendDebugCommand(handle, "vAttach;\(String(launched.pid, radix: 16))")
            }
            note("vAttach → \(attach.isEmpty ? "(no reply)" : attach)")
            guard attach.hasPrefix("OK") || attach.first == "T" || attach.first == "S" else {
                throw DeviceConnection.DebugError(
                    message: L("The debugger refused to attach (%@). The app may already be running, or this iOS may not allow it.", attach.isEmpty ? L("no reply") : attach))
            }
            try await engine.onDeviceQueue { () -> Void in
                // 3. Let it run. The connection stays open, which keeps the
                //    debugger attached and with it the executable-mapping right.
                let reply = try device.sendDebugCommand(handle, "c")
                self.note("resume → \(reply.isEmpty ? "running" : reply)")
            }
            state = .running(pid: UInt32(truncatingIfNeeded: launched.pid))
            note("JIT is on. Keep this session open while you use the app.")
            watchSession()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            note("Failed: \(message)")
            state = .failed(message)
            cleanup()
        }
    }

    /// Ends the session: the debugger detaches and the permission goes with it.
    func stop() async {
        guard isActive || state == .attaching else {
            cleanup()
            state = .idle
            return
        }
        let engine = Engine.shared
        let handle = proxy
        let target = pid
        proxy = nil
        pid = 0
        if let handle {
            try? await engine.onDeviceQueue { engine.connection.closeDebugProxy(handle) }
        }
        // Closing the proxy leaves the process stopped at its interrupt; it's
        // killed so nothing is left half-debugged.
        if target != 0 {
            try? await engine.onDeviceQueue { try engine.connection.killDebugProcess(pid: target) }
        }
        note("Session ended.")
        bundleID = nil
        state = .idle
    }

    // MARK: - The open connection

    /// Holds the session open for as long as it should last.
    ///
    /// Nothing is read from the proxy on purpose: a stopped process gets only
    /// one stop reply, and anything aimed at the socket while the app is running
    /// would have to interrupt it. Instead the process is checked out of band
    /// through DVT, so an app the user quits stops the session and frees the
    /// debugger for the next one.
    private func watchSession() {
        let engine = Engine.shared
        let pidAtStart = pid
        let bundleAtStart = bundleID
        Task {
            while proxy != nil, pid == pidAtStart {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard proxy != nil, pid == pidAtStart, let bundleAtStart else { return }
                let running = (try? await engine.onDeviceQueue {
                    try engine.connection.isProcessRunning(bundleID: bundleAtStart)
                }) ?? true
                if !running {
                    note("The app exited.")
                    await stop()
                    state = .idle
                    return
                }
            }
        }
    }

    private func cleanup() {
        if let handle = proxy {
            Engine.shared.connection.closeDebugProxy(handle)
            proxy = nil
        }
        pid = 0
        bundleID = nil
    }

    private func note(_ line: String) {
        log.append(line)
        Engine.shared.log("JIT: \(line)")
    }

    /// The session's report, for the Info sheet.
    var transcript: [String] { log }
}
