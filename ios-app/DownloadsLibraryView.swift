import SwiftUI

/// **Downloads**: the `.ipa` files already on this iPhone — the preset builds a
/// previous run fetched, and anything imported from Files — with the choice the
/// marketplace row no longer makes for you: configure it in the install menu, or
/// install it straight away.
///
/// Compact by design: a row is one line — icon, app name, size — with the two
/// actions at its end, so a phone with twenty downloads is one screen and a
/// half, not four.
struct DownloadsLibraryView: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    @StateObject private var manager = DownloadsManager()
    @State private var pendingDelete: DownloadedIPA?
    /// What the last cleanup did.
    @State private var cleanupNote: String?
    /// The name the app calls itself, read out of the `.ipa`'s own Info.plist.
    /// A file downloaded as `com.burbn.instagram.ipa` is still Instagram.
    @State private var appNames: [String: String] = [:]
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    searchField
                    if visible.isEmpty {
                        emptyState
                    } else {
                        ForEach(visible) { item in
                            row(item)
                        }
                        cleanupCard
                    }
                }
                .padding(14)
                .pageColumn()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppBackground())
            .navigationTitle(L("Downloads"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .onAppear {
                manager.refresh()
                readNames()
            }
            .onChange(of: manager.downloads.count) { _, _ in readNames() }
            .confirmationDialog(L("Delete this download?"),
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                presenting: pendingDelete) { item in
                Button(L("Delete %@", name(item)), role: .destructive) {
                    manager.delete(item)
                    pendingDelete = nil
                    Haptics.destructive()
                }
                Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
            } message: { item in
                Text(L("%@ (%@) is removed from this iPhone. An app already installed from it stays.",
                       name(item), item.sizeText))
            }
        }
    }

    /// One build per app, on demand: the same cleanup runs after every install.
    private var cleanupCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Older builds"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(L("Keep only the newest .ipa of each app. Older downloads of the same app are deleted; the app installed from them is untouched."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    let result = DownloadsManager.keepNewestOnly()
                    manager.refresh()
                    cleanupNote = result.removed == 0
                        ? L("Every app already has a single build here.")
                        : L("Removed %d older build(s), %@ back.", result.removed,
                            ByteCountFormatter.string(fromByteCount: Int64(result.freed), countStyle: .file))
                    Haptics.success()
                } label: {
                    Label(L("Remove older builds"), systemImage: "arrow.down.to.line.compact")
                }
                .buttonStyle(SecondaryButtonStyle())
                if let cleanupNote {
                    Text(cleanupNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(L("Search downloads"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .font(.subheadline)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .fieldBackground()
        .padding(.bottom, 4)
    }

    private var visible: [DownloadedIPA] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return manager.downloads }
        return manager.downloads.filter { item in
            name(item).lowercased().contains(term)
                || item.fileName.lowercased().contains(term)
                || item.displayName.lowercased().contains(term)
        }
    }

    // MARK: Rows

    private func row(_ item: DownloadedIPA) -> some View {
        HStack(spacing: 10) {
            icon(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(name(item))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detail(item))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)

            // The two things a row is for, at its end.
            Button { configure(item) } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
                    .foregroundStyle(Theme.accent2)
            }
            .buttonStyle(.plain)
            .disabled(engine.isRunning || engine.isImportingIPA)
            .accessibilityLabel(L("Configure %@", name(item)))

            Button { install(item) } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(engine.isRunning || engine.isImportingIPA)
            .accessibilityLabel(L("Install %@", name(item)))

            Menu {
                ShareLink(item: item.url) {
                    Label(L("Share the file"), systemImage: "square.and.arrow.up")
                }
                Button {
                    configure(item)
                } label: {
                    Label(L("Configure in Install"), systemImage: "slider.horizontal.3")
                }
                Divider()
                Button(role: .destructive) {
                    pendingDelete = item
                } label: {
                    Label(L("Delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .cardSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    private func icon(_ item: DownloadedIPA) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.brand)
            Image(systemName: symbol(item))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
    }

    private func symbol(_ item: DownloadedIPA) -> String {
        switch item.source {
        case .sideStore:     return "shippingbox.fill"
        case .liveContainer: return "square.stack.3d.up.fill"
        case .madeira:       return "bolt.horizontal.circle.fill"
        case .custom:        return "doc.fill"
        }
    }

    /// The app's own name, else what the manager calls it, else the file.
    private func name(_ item: DownloadedIPA) -> String {
        if let read = appNames[item.url.path], !read.isEmpty { return read }
        return item.displayName
    }

    private func detail(_ item: DownloadedIPA) -> String {
        var parts = [item.sizeText]
        if let date = item.modified {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        // The file name is only worth a line when it isn't the name above it.
        if item.fileName != name(item) { parts.append(item.fileName) }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    /// Imports the file as the custom build and lands on the Install tab, where
    /// the signing configuration is waiting.
    private func configure(_ item: DownloadedIPA) {
        Haptics.tap()
        Task { await engine.importCustomIPA(from: item.url) }
        dismiss()
    }

    /// Imports and runs in one go, for when nothing needs changing.
    private func install(_ item: DownloadedIPA) {
        Haptics.tap()
        engine.installLocalIPA(at: item.url)
        dismiss()
    }

    /// Reads each archive's `CFBundleDisplayName` off the main actor. A download
    /// named after its bundle ID is still Instagram on the row.
    private func readNames() {
        let items = manager.downloads
        guard !items.isEmpty else { return }
        Task {
            let read = await Task.detached(priority: .utility) { () -> [String: String] in
                var names: [String: String] = [:]
                for item in items {
                    guard let info = IPAPatch.readInfoPlist(from: item.url) else { continue }
                    let name = (info["CFBundleDisplayName"] as? String)
                        ?? (info["CFBundleName"] as? String) ?? ""
                    if !name.isEmpty { names[item.url.path] = name }
                }
                return names
            }.value
            appNames.merge(read) { _, new in new }
        }
    }

    private var emptyState: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(query.isEmpty ? L("Nothing downloaded yet") : L("Nothing matches that"))
                    .font(.headline)
                Text(query.isEmpty
                     ? L("A preset build is kept here after it downloads, and an .ipa opened from Files or a link is kept too. Either can be handed to the install menu from this page.")
                     : L("Every download is listed above — try the app's name, or part of the file name."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
