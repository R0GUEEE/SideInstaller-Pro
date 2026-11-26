import SwiftUI
import UniformTypeIdentifiers

/// The tweaks kept on this iPhone but not yet in a build: `.dylib` files and
/// `.deb` packages, plus bundles that group them under a name ("My jailbreak
/// setup") and add them all at once.
struct StoredTweak: Codable, Identifiable, Equatable {
    var id = UUID()
    var fileName: String
    var added = Date()

    var isDeb: Bool { fileName.lowercased().hasSuffix(".deb") }
    var title: String { (fileName as NSString).deletingPathExtension }
}

/// A named group of stored tweaks, applied together.
struct TweakBundle: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// The stored tweaks' ids.
    var members: [UUID]
    var created = Date()
}

/// The library behind the Tweak storage page.
///
/// Files live in `Application Support/TweakLibrary`; the index is a small JSON
/// file beside them. Applying an item copies it into the app configuration,
/// which is the one place that unpacks a `.deb` and decides what to inject.
/// The class stays non-isolated so `shared` can be read from a view property
/// initializer; everything that mutates it is main-actor bound.
final class TweakLibrary: ObservableObject {

    static let shared = TweakLibrary()

    @Published private(set) var items: [StoredTweak] = []
    @Published private(set) var bundles: [TweakBundle] = []

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TweakLibrary", isDirectory: true)
    }

    private static var indexFile: URL { directory.appendingPathComponent("library.json") }

    private struct Index: Codable {
        var items: [StoredTweak]
        var bundles: [TweakBundle]
    }

    private init() {
        guard let data = try? Data(contentsOf: Self.indexFile),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        items = index.items
        bundles = index.bundles
        // A file removed outside the app shouldn't stay in the list.
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? [])
        items.removeAll { !existing.contains($0.fileName) }
    }

    // MARK: Files

    @MainActor
    @discardableResult
    func add(_ urls: [URL]) -> (added: Int, failed: [String]) {
        var added = 0
        var failed: [String] = []
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for url in urls {
            let name = url.lastPathComponent
            let lowered = name.lowercased()
            guard lowered.hasSuffix(".dylib") || lowered.hasSuffix(".deb") else {
                failed.append(name)
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let destination = Self.directory.appendingPathComponent(name)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                items.removeAll { $0.fileName == name }
                items.append(StoredTweak(fileName: name))
                added += 1
            } catch {
                failed.append(name)
            }
        }
        items.sort { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
        save()
        return (added, failed)
    }

    @MainActor
    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(item.fileName))
        items.removeAll { $0.id == id }
        // A bundle that loses its last member is not a bundle any more.
        bundles = bundles.compactMap { bundle in
            var bundle = bundle
            bundle.members.removeAll { $0 == id }
            return bundle.members.isEmpty ? nil : bundle
        }
        save()
    }

    func url(for item: StoredTweak) -> URL {
        Self.directory.appendingPathComponent(item.fileName)
    }

    // MARK: Bundles

    @MainActor
    func createBundle(named name: String, members: [UUID]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !members.isEmpty else { return }
        bundles.append(TweakBundle(name: trimmed, members: members))
        bundles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    @MainActor
    func deleteBundle(_ id: UUID) {
        bundles.removeAll { $0.id == id }
        save()
    }

    func members(of bundle: TweakBundle) -> [StoredTweak] {
        bundle.members.compactMap { id in items.first { $0.id == id } }
    }

    // MARK: Applying

    /// Copies the tweaks into the app configuration, the same path a picked file
    /// takes. Returns how many were added and which couldn't be.
    @MainActor
    @discardableResult
    func apply(_ tweaks: [StoredTweak]) -> (added: Int, failed: [String]) {
        let urls = tweaks.map(url(for:))
        return AppConfigStore.shared.addTweaks(urls)
    }

    // MARK: Index

    @MainActor
    private func save() {
        let index = Index(items: items, bundles: bundles)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.indexFile, options: .atomic)
    }
}

/// **Tools › Tweak storage**: the tweaks kept on the iPhone, and bundles of
/// them, so a build can be given the same set without hunting for files.
struct TweakLibraryView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var library = TweakLibrary.shared
    @ObservedObject private var config = AppConfigStore.shared

    @State private var showImporter = false
    @State private var showNewBundle = false
    @State private var note: String?
    @State private var pendingDelete: StoredTweak?
    /// The injector whose file picker is up, and whether it is.
    @State private var pendingInjectorKind: TweakInjectorKind?
    @State private var showInjectorImporter = false
    @State private var pendingBundleDelete: TweakBundle?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                BrandHeader(icon: "tray.full.fill", title: L("Tweak storage")) {
                    if !library.items.isEmpty {
                        StatusPill(text: L("%d tweak(s)", library.items.count),
                                   systemImage: "shippingbox", color: Theme.accent2)
                    }
                }
                .cascadeItem(0)

                if let note {
                    PanelCard {
                        Text(note)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .cascadeItem(1)
                }

                addCard.cascadeItem(2)
                itemsCard.cascadeItem(3)
                bundlesCard.cascadeItem(4)
                injectorsCard.cascadeItem(5)
                Text(L("A tweak added here is copied into the app configuration when you apply it, so the same file can be used by more than one build. Bundles are just names for a set: applying one adds every file it holds."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .cascadeItem(5)
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
        .sheet(isPresented: $showImporter) {
            FileImporterRepresentableView(allowedContentTypes: [.dylib, .deb],
                                          allowsMultipleSelection: true) { urls in
                guard !urls.isEmpty else { return }
                let result = library.add(urls)
                note = result.failed.isEmpty
                    ? L("Added %d tweak(s).", result.added)
                    : L("Couldn't add %@.", result.failed.joined(separator: ", "))
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showNewBundle) {
            NewBundleSheet(library: library)
        }
        .sheet(isPresented: $showInjectorImporter) {
            FileImporterRepresentableView(allowedContentTypes: [.dylib]) { urls in
                guard let kind = pendingInjectorKind, let url = urls.first else { return }
                _ = config.addInjector(kind, from: url)
                pendingInjectorKind = nil
            }
            .ignoresSafeArea()
        }
        .confirmationDialog(L("Delete this tweak?"),
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { item in
            Button(L("Delete %@", item.title), role: .destructive) {
                library.remove(item.id)
                pendingDelete = nil
                Haptics.destructive()
            }
            Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text(L("The file is deleted from this iPhone. A build that already has it keeps it."))
        }
        .confirmationDialog(L("Delete this bundle?"),
                            isPresented: Binding(get: { pendingBundleDelete != nil },
                                                 set: { if !$0 { pendingBundleDelete = nil } }),
                            presenting: pendingBundleDelete) { bundle in
            Button(L("Delete %@", bundle.name), role: .destructive) {
                library.deleteBundle(bundle.id)
                pendingBundleDelete = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingBundleDelete = nil }
        } message: { _ in
            Text(L("Only the grouping goes; the tweaks stay in the list."))
        }
    }

    // MARK: Add

    private var addCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Add tweaks"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button { showImporter = true } label: {
                    Label(L("Import .dylib or .deb"), systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                Text(L("Or add one from the Tweak browser: a package added to the configuration also stores its .deb here, so it can be reused."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Items

    @ViewBuilder
    private var itemsCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("Tweaks"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !library.items.isEmpty {
                        Text(L("%d", library.items.count))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if library.items.isEmpty {
                    Text(L("Nothing stored yet. A .dylib or .deb is kept here, ready to add to any build, and a bundle groups several under one name."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(library.items) { item in
                    Divider().opacity(0.12)
                    row(item)
                }
            }
        }
    }

    private func row(_ item: StoredTweak) -> some View {
        let applied = config.config.tweaks.contains {
            ($0.path as NSString).lastPathComponent.lowercased() == item.fileName.lowercased()
        }
        return HStack(spacing: 10) {
            Image(systemName: item.isDeb ? "shippingbox.fill" : "doc.fill")
                .font(.footnote)
                .foregroundStyle(Theme.accent2)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(item.fileName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if applied {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(L("In the configuration"))
            } else {
                Button {
                    let result = library.apply([item])
                    note = result.added == 1
                        ? L("Added %@ to the app configuration.", item.title)
                        : L("%@ couldn't be added: nothing in it can be injected.", item.title)
                    if result.added == 1 { Haptics.success() } else { Haptics.warning() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Add %@ to the configuration", item.title))
            }
            Menu {
                Button {
                    let result = library.apply([item])
                    note = result.added == 1 ? L("Added %@.", item.title)
                                             : L("Nothing in %@ can be injected.", item.title)
                } label: {
                    Label(L("Add to the configuration"), systemImage: "plus.circle")
                }
                Button {
                    UIPasteboard.general.url = library.url(for: item)
                } label: {
                    Label(L("Copy the file's location"), systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive) {
                    pendingDelete = item
                } label: {
                    Label(L("Delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }

    // MARK: Injection frameworks

    /// The loaders a tweak hooks through. They live here rather than in the
    /// install menu because they're part of the toolkit, not part of one build:
    /// adding ElleKit once serves every install that needs it.
    private var injectorsCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Injection frameworks"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(TweakInjectorKind.allCases) { kind in
                    Divider().opacity(0.12)
                    injectorRow(kind)
                }
                if !config.missingInjectors.isEmpty {
                    Text(L("Needed by an added tweak: %@.",
                           config.missingInjectors.map(\.title).joined(separator: ", ")))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("ElleKit and Substitute can be downloaded; CydiaSubstrate and libhooker are closed, so they're added from a copy you have. A tweak that names one in its dependencies gets it loaded beside it."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func injectorRow(_ kind: TweakInjectorKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line")
                .font(.caption2)
                .foregroundStyle(Theme.accent2)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                if let installed = config.injector(for: kind) {
                    Text(installed.fileName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let status = config.injectorStatus[kind] {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("Not added"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            if config.injector(for: kind) != nil {
                Button(role: .destructive) {
                    config.removeInjector(kind)
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    Task { await config.downloadInjector(kind) }
                } label: {
                    Image(systemName: "arrow.down.circle").font(.footnote)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Download %@", kind.title))
                Button {
                    pendingInjectorKind = kind
                    showInjectorImporter = true
                } label: {
                    Image(systemName: "folder.badge.plus").font(.footnote)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Add %@ from a file", kind.title))
            }
        }
        .padding(.vertical, 3)
    }
    // MARK: Bundles

    @ViewBuilder
    private var bundlesCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("Bundles"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showNewBundle = true
                    } label: {
                        Label(L("New"), systemImage: "plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(library.items.isEmpty)
                }
                if library.bundles.isEmpty {
                    Text(L("A bundle is a name for a set of tweaks — “my setup” — so one tap adds all of them to a build."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(library.bundles) { bundle in
                    Divider().opacity(0.12)
                    bundleRow(bundle)
                }
            }
        }
    }

    private func bundleRow(_ bundle: TweakBundle) -> some View {
        let members = library.members(of: bundle)
        return HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.footnote)
                .foregroundStyle(Theme.accent2)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(bundle.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(members.map(\.title).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                let result = library.apply(members)
                note = result.added > 0
                    ? L("Added %d tweak(s) from %@.", result.added, bundle.name)
                    : L("Nothing in %@ could be added.", bundle.name)
                if result.added > 0 { Haptics.success() } else { Haptics.warning() }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(members.isEmpty)
            .accessibilityLabel(L("Add every tweak in %@", bundle.name))
            Menu {
                Button(role: .destructive) {
                    pendingBundleDelete = bundle
                } label: {
                    Label(L("Delete the bundle"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }
}

/// Naming a bundle and ticking what goes in it.
private struct NewBundleSheet: View {
    @ObservedObject var library: TweakLibrary

    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var picked: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Name, e.g. My setup"), text: $name)
                } header: {
                    Text(L("Bundle"))
                }
                Section {
                    ForEach(library.items) { item in
                        Button {
                            if picked.contains(item.id) { picked.remove(item.id) }
                            else { picked.insert(item.id) }
                        } label: {
                            HStack {
                                Image(systemName: item.isDeb ? "shippingbox" : "doc")
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: picked.contains(item.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(item.id)
                                                     ? Theme.accent2 : Color.secondary)
                            }
                        }
                    }
                } header: {
                    Text(L("Tweaks"))
                }
            }
            .navigationTitle(L("New bundle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Create")) {
                        library.createBundle(named: name, members: Array(picked))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || picked.isEmpty)
                }
            }
        }
    }
}
