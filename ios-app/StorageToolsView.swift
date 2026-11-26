import SwiftUI
import UIKit

/// The builds SideInstaller keeps, so they can be reinstalled or re-signed later.
///
/// One row per app: its cached `.ipa`, how big it is, when it was kept, and the
/// things worth doing with it — install it again, share it, or delete the copy.
struct IPACacheView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var engine: Engine

    @State private var entries: [IPACache.Cached] = []
    /// Summed from `entries` rather than re-scanning the folder: the header used
    /// to call `IPACache.totalBytes()` on every redraw, which listed and stat-ed
    /// the whole cache each time.
    @State private var totalBytes: Int64 = 0
    @State private var pendingDelete: IPACache.Cached?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                header.cascadeItem(0)
                if entries.isEmpty {
                    emptyCard.cascadeItem(1)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry).cascadeItem(min(index + 1, 6))
                    }
                    Text(L("Copies of builds SideInstaller installed, kept so an app can be re-signed after its download is gone. Deleting one doesn't remove the app — it only means My Apps can no longer renew it without the .ipa again."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .cascadeItem(7)
                }
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
        .onAppear { Task { await load() } }
        .confirmationDialog(L("Delete this copy?"),
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { entry in
            Button(L("Delete %@", entry.displayName), role: .destructive) {
                IPACache.remove(entry.bundleID)
                pendingDelete = nil
                Task { await load() }
            }
            Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text(L("%@ (%@) is removed from storage. The app stays installed.", entry.displayName, entry.sizeText))
        }
    }

    private var header: some View {
        BrandHeader(icon: "internaldrive.fill", title: L("Stored builds")) {
            if !entries.isEmpty {
                StatusPill(text: ByteCountFormatter.string(fromByteCount: totalBytes,
                                                           countStyle: .file),
                           systemImage: "shippingbox.fill", color: Theme.accent2)
            }
        }
    }

    /// The folder, read off the main actor, and its size taken from what was
    /// read rather than from a second pass.
    @MainActor
    private func load() async {
        let all = await IPACache.load()
        entries = all
        totalBytes = all.reduce(Int64(0)) { $0 + $1.bytes }
    }

    private var emptyCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Nothing stored yet"))
                    .font(.headline)
                Text(L("Install an app with SideInstaller and its .ipa is kept here. My Apps then re-signs it whenever its seven days run out, even if the original download is gone."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ entry: IPACache.Cached) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shippingbox.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(entry.bundleID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(L("%@ · kept %@", entry.sizeText,
                               entry.savedAt.formatted(date: .abbreviated, time: .omitted)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Button {
                        engine.installLocalIPA(at: entry.url)
                    } label: {
                        Label(L("Install"), systemImage: "square.and.arrow.down")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        share(entry.url)
                    } label: {
                        Label(L("Share"), systemImage: "square.and.arrow.up")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        pendingDelete = entry
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 32, height: 30)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func share(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var controller = root
        while let presented = controller.presentedViewController { controller = presented }
        controller.present(UIActivityViewController(activityItems: [url], applicationActivities: nil),
                           animated: true)
    }
}

/// What the device says about itself, and where the app's files live.
///
/// Cheap to answer without the device (the OS version, the app's own storage) and
/// richer when the link is open (UDID, model, iOS build).
struct DeviceInfoView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var engine: Engine

    @State private var detail: Engine.DeviceDetail?
    /// The storage card, measured once when the page appears instead of on every
    /// redraw — the container walk below takes seconds on a full device.
    @State private var storageRows: [(String, String)] = []
    @State private var measuringStorage = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                BrandHeader(icon: "iphone.gen3", title: L("Device")) { EmptyView() }
                    .cascadeItem(0)

                PanelCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L("This iPhone"), systemImage: "iphone")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        row(L("iOS"), ProcessInfo.processInfo.operatingSystemVersionString)
                        row(L("Model"), detail?.model ?? UIDevice.current.model)
                        row(L("Name"), detail?.name ?? UIDevice.current.name)
                        row(L("UDID"), detail?.udid ?? engine.deviceUDID ?? L("Connect to read it"))
                        row(L("Build"), detail?.build ?? "—")
                    }
                }
                .cascadeItem(1)

                PanelCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L("Storage"), systemImage: "internaldrive")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(storageRows, id: \.0) { pair in
                            row(pair.0, pair.1)
                        }
                        if measuringStorage {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(L("Measuring…"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .cascadeItem(2)

                Button {
                    Task { await load() }
                } label: {
                    Label(detail == nil ? L("Read from the device") : L("Read again"),
                          systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(engine.isRunning)
                .cascadeItem(3)
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
        .onAppear(perform: measureStorage)
    }

    /// Volume figures and the container's size, measured off the main actor.
    /// `StorageReport.size` walks every file in the app container, documents
    /// and caches included, so it is the one number on this page that must never
    /// be computed in a body.
    @MainActor
    private func measureStorage() {
        guard !measuringStorage else { return }
        measuringStorage = true
        Task {
            let facts = await Task.detached(priority: .utility) { () -> StorageFacts in
                let home = URL(fileURLWithPath: NSHomeDirectory())
                let values = try? home.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
                return StorageFacts(
                    free: values?.volumeAvailableCapacityForImportantUsage,
                    total: values?.volumeTotalCapacity.map(Int64.init),
                    container: StorageReport.size(of: home),
                    stored: IPACache.totalBytes())
            }.value

            var rows: [(String, String)] = []
            if let free = facts.free {
                rows.append((L("Free"), ByteCountFormatter.string(fromByteCount: free, countStyle: .file)))
            }
            if let total = facts.total {
                rows.append((L("Total"), ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
            }
            rows.append((L("Stored builds"),
                         ByteCountFormatter.string(fromByteCount: facts.stored, countStyle: .file)))
            rows.append((L("App container"),
                         ByteCountFormatter.string(fromByteCount: facts.container, countStyle: .file)))
            storageRows = rows
            measuringStorage = false
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func load() async {
        do {
            detail = try await engine.readDeviceDetail()
        } catch {
            engine.log("Device details: \(error.localizedDescription)")
        }
    }
}


/// What the storage card needs, carried back from the background.
private struct StorageFacts {
    let free: Int64?
    let total: Int64?
    let container: Int64
    let stored: Int64
}
