import Foundation
import Combine

// Only the device-facing boundary is substituted; queue, cache, staging and
// history below are the production implementations.
func L(_ text: String) -> String { text }
final class Engine {
    static let shared = Engine()
    func log(_ text: String) { print(text) }
    @MainActor func installQueuedIPA(_ url: URL) async throws { fatalError("Inject a test installer") }
}

enum TestError: Error { case installFailed }
@MainActor final class Gate {
    var started = false
    var reply: CheckedContinuation<Void, Error>?
    func wait() async throws {
        started = true
        try await withCheckedThrowingContinuation { reply = $0 }
    }
    func finish(_ error: Error? = nil) {
        if let error { reply?.resume(throwing: error) } else { reply?.resume() }
        reply = nil
    }
}

@main struct Regression {
    static func check(_ condition: @autoclosure () throws -> Bool) rethrows {
        let passed = try condition()
        precondition(passed)
    }
    @MainActor static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out")
    }

    @MainActor static func main() async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let first = work.appendingPathComponent("first.ipa")
        let second = work.appendingPathComponent("second.ipa")
        try Data("version one".utf8).write(to: first)
        try Data("version two".utf8).write(to: second)
        let id = "com.example.regression." + UUID().uuidString
        defer { IPACache.remove(id) }
        guard let cache = IPACache.store(first, bundleID: id, displayName: "Test") else {
            fatalError("A new bundle ID must create a cache file")
        }
        try check(Data(contentsOf: cache.url) == Data("version one".utf8))
        assert(IPACache.store(second, bundleID: id, displayName: "Test") != nil)
        try check(Data(contentsOf: cache.url) == Data("version two".utf8))

        let history = InstallHistory.shared
        history.clear()
        history.record(bundleID: id, name: "Test", version: "1", cached: first, origin: nil)
        history.record(bundleID: id, name: "Test", version: "2", cached: second, origin: nil)
        guard let old = history.previousBuild(of: id)?.cachedURL else { fatalError("No rollback copy") }
        assert(old != history.entries.first?.cachedURL)
        try check(Data(contentsOf: old) == Data("version one".utf8))
        let legacy = InstallHistory.Entry(id: UUID(), bundleID: id, name: "Test", version: "0",
            cachedPath: cache.url.path, date: Date(), origin: nil)
        assert(legacy.cachedURL == nil, "Mutable legacy caches must not masquerade as old builds")
        history.clear()
        assert(!fm.fileExists(atPath: old.path))
        assert(fm.fileExists(atPath: cache.url.path))

        let another = work.appendingPathComponent("other")
        try fm.createDirectory(at: another, withIntermediateDirectories: true)
        let sameName = another.appendingPathComponent(first.lastPathComponent)
        try Data("different file".utf8).write(to: sameName)
        let stagedA = try BulkInstallStage.stage(first)
        let stagedB = try BulkInstallStage.stage(sameName)
        assert(stagedA != stagedB)
        try check(Data(contentsOf: stagedA) != Data(contentsOf: stagedB))
        BulkInstallStage.prune(keeping: [stagedB])
        assert(!fm.fileExists(atPath: stagedA.path))
        assert(fm.fileExists(atPath: stagedB.path))
        BulkInstallStage.prune(keeping: [])

        let gate = Gate()
        var calls = 0
        let queue = InstallQueue { _ in
            calls += 1
            if calls == 1 { try await gate.wait() }
            else { throw TestError.installFailed }
        }
        queue.add(name: "First", url: first)
        queue.add(name: "Second", url: second)
        queue.start()
        try await until { gate.started }
        assert(queue.items[0].state == .installing)
        assert(queue.items[1].state == .waiting)
        gate.finish()
        try await until { queue.items[1].isFinished }
        assert(queue.items[0].state == .done)
        if case .failed = queue.items[1].state {} else { fatalError("Failed install marked successful") }
        queue.cancel()
        try await until { !queue.isRunning }

        let cancelGate = Gate()
        let cancelled = InstallQueue { _ in try await cancelGate.wait() }
        cancelled.add(name: "First", url: first)
        cancelled.add(name: "Second", url: second)
        cancelled.start()
        try await until { cancelGate.started }
        cancelled.cancel()
        assert(cancelled.isRunning, "Cancellation must wait for in-flight work to stop")
        cancelGate.finish()
        try await until { !cancelled.isRunning }
        for item in cancelled.items {
            if case .failed = item.state {} else { fatalError("Cancelled install marked successful") }
        }
        print("PASS: first cache, replacement, immutable rollback, staging collisions, queue completion and cancellation")
    }
}
