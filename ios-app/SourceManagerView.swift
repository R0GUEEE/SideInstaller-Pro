import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// A list of source links: one per line, or any text or JSON holding them.
    static let sourceList = UTType(filenameExtension: "txt") ?? .plainText
}

/// Every configured source in one place: add several at a time, refresh them all,
/// enable, remove, or export the list.
///
/// The marketplace's chips answer "where do I look"; this answers "what's in my
/// sources and are they healthy", which is a different job and belongs in its
/// own sheet rather than on the browsing screen.
struct SourceManagerView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var store: SourceStore
    @Environment(\.dismiss) private var dismiss

    /// Several links pasted at once, one per line.
    @State private var bulkText = ""
    @State private var working = false
    /// What the last bulk run did.
    @State private var report: String?
    /// The source pending removal.
    @State private var pendingRemove: SourceStore.Loaded?
    @State private var showImporter = false
    @State private var showMarket = false
    @State private var showTelegram = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    marketCard
                    telegramCard
                    bulkCard
                    listCard
                    exportCard
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("Sources"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .alert(L("Remove this source?"),
                   isPresented: Binding(get: { pendingRemove != nil },
                                        set: { if !$0 { pendingRemove = nil } }),
                   presenting: pendingRemove) { loaded in
                Button(L("Remove"), role: .destructive) {
                    store.remove(loaded.id)
                    pendingRemove = nil
                }
                Button(L("Cancel"), role: .cancel) { pendingRemove = nil }
            } message: { loaded in
                Text(L("Its %ld apps leave the marketplace. The source itself isn't changed, and adding it again restores them.", loaded.appCount))
            }
            .sheet(isPresented: $showTelegram) {
                TelegramStudioView().environmentObject(loc)
            }
            .sheet(isPresented: $showMarket) {
                RepositoryMarketView(store: store)
                    .environmentObject(loc)
            }
            .sheet(isPresented: $showImporter) {
                FileImporterRepresentableView(allowedContentTypes: [.sourceList, .json]) { urls in
                    guard let url = urls.first else { return }
                    // A file of links is the same thing as pasting them.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        bulkText = text
                        Task { await addBulk() }
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    /// The curated repository list, for a new install with nothing in it.
    private var marketCard: some View {
        Button {
            showMarket = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.brand)
                    Image(systemName: "storefront.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Repository market"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L("Popular sources to add in one tap"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .cardSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Telegram channels: scan them, then turn the result into a source.
    private var telegramCard: some View {
        Button {
            showTelegram = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.brand)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Telegram channels"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L("Scan channels and generate a source from them"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .cardSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Bulk add

    private var bulkCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L("Add several sources"), systemImage: "text.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(L("One link per line — `altstore://source?url=…` links work too. A text or JSON file of links can be chosen instead."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $bulkText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.06)))

                HStack(spacing: 10) {
                    Button {
                        Task { await addBulk() }
                    } label: {
                        Label(L("Add %ld", linkedCount), systemImage: "plus")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(linkedCount == 0 || working)

                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "doc.badge.plus")
                            .frame(width: 36, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(working)
                }

                if working || !store.isAdding {
                    if working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Adding…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let report {
                        Text(report)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// How many usable links are in the box, which is what the button promises.
    private var linkedCount: Int {
        bulkText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .filter { SourceStore.sourceURL(from: $0) != nil }
            .count
    }

    private func addBulk() async {
        let links = bulkText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !links.isEmpty else { return }
        working = true
        report = nil
        // One at a time through the store: each add fetches and indexes, and
        // the store is the thing that has to stay consistent.
        var added = 0
        var failures: [String] = []
        for link in links {
            if store.sources.contains(where: { $0.url.absoluteString == link }) { continue }
            if let error = await store.add(link) {
                failures.append("\(link) — \(error)")
            } else {
                added += 1
            }
        }
        working = false
        bulkText = ""
        report = failures.isEmpty
            ? L("Added %d source(s).", added)
            : L("Added %d. %d didn't load: %@", added, failures.count,
                failures.prefix(3).joined(separator: "\n"))
    }

    // MARK: The list

    private var listCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L("%ld sources", store.sources.count), systemImage: "shippingbox")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        Label(L("Refresh all"), systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }

                if store.sources.isEmpty {
                    Text(L("No sources yet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(store.sources) { loaded in
                    row(loaded)
                    if loaded.id != store.sources.last?.id { Divider().opacity(0.15) }
                }
            }
        }
    }

    private func row(_ loaded: SourceStore.Loaded) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SourceIcon(url: loaded.icon, side: 34, fallback: "shippingbox.fill", corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(loaded.name.isEmpty ? (loaded.url.host ?? loaded.url.absoluteString) : loaded.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(L("%ld apps", store.count(for: loaded.id)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let date = loaded.fetched {
                        Text("· \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let date = loaded.fetched,
                       Date().timeIntervalSince(date) > 6 * 60 * 60 {
                        Text(L("· cached"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let error = loaded.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let channel = loaded.telegramChannel,
                       let link = URL(string: "https://t.me/\(channel)") {
                        Button {
                            UIApplication.shared.open(link)
                        } label: {
                            Label(L("Open in Telegram"), systemImage: "paperplane")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Spacer(minLength: 4)
            if loaded.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await store.refresh(loaded.id) }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.footnote)
                }
                .buttonStyle(.borderless)
            }
            Button(role: .destructive) {
                pendingRemove = loaded
            } label: {
                Image(systemName: "trash").font(.footnote)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    // MARK: Export

    private var exportCard: some View {
        Button {
            let text = store.sources.map(\.url.absoluteString).joined(separator: "\n")
            share(text.data(using: .utf8), name: "sources.txt")
        } label: {
            Label(L("Export the list"), systemImage: "square.and.arrow.up")
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(store.sources.isEmpty)
    }

    private func share(_ data: Data?, name: String) {
        guard let data else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url)
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
