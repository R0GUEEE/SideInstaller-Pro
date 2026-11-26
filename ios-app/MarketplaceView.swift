import SwiftUI
import UIKit

/// A category an app can be filed under, in the vocabulary AltStore sources
/// use, with the name and symbol an App Store-style grid wants.
struct MarketCategory: Identifiable, Hashable {
    let id: String        // the source's `category` value
    let title: String
    let icon: String

    /// Every category a source may name. Unknown ones fall back to `other`.
    /// Computed rather than stored so the names follow a language change.
    static var all: [MarketCategory] { [
        .init(id: "utilities", title: L("Utilities"), icon: "wrench.and.screwdriver.fill"),
        .init(id: "games", title: L("Games"), icon: "gamecontroller.fill"),
        .init(id: "developer", title: L("Developer"), icon: "hammer.fill"),
        .init(id: "social", title: L("Social"), icon: "person.2.fill"),
        .init(id: "entertainment", title: L("Entertainment"), icon: "play.tv.fill"),
        .init(id: "education", title: L("Education"), icon: "graduationcap.fill"),
        .init(id: "graphics-design", title: L("Graphics & Design"), icon: "paintpalette.fill"),
        .init(id: "health-fitness", title: L("Health & Fitness"), icon: "heart.fill"),
        .init(id: "lifestyle", title: L("Lifestyle"), icon: "sparkles"),
        .init(id: "music", title: L("Music"), icon: "music.note"),
        .init(id: "news", title: L("News"), icon: "newspaper.fill"),
        .init(id: "photo-video", title: L("Photo & Video"), icon: "camera.fill"),
        .init(id: "productivity", title: L("Productivity"), icon: "checklist"),
        .init(id: "travel", title: L("Travel"), icon: "airplane"),
        .init(id: "weather", title: L("Weather"), icon: "cloud.sun.fill"),
        .init(id: "books", title: L("Books"), icon: "book.fill"),
        .init(id: "business", title: L("Business"), icon: "briefcase.fill"),
        .init(id: "finance", title: L("Finance"), icon: "dollarsign.circle.fill"),
        .init(id: "medical", title: L("Medical"), icon: "cross.case.fill"),
        .init(id: "navigation", title: L("Navigation"), icon: "map.fill"),
        .init(id: "reference", title: L("Reference"), icon: "text.book.closed.fill"),
        .init(id: "shopping", title: L("Shopping"), icon: "bag.fill"),
        .init(id: "sports", title: L("Sports"), icon: "figure.run"),
        .init(id: "food-drink", title: L("Food & Drink"), icon: "fork.knife"),
        .init(id: "other", title: L("Other"), icon: "square.grid.2x2.fill"),
    ] }

    private static var byID: [String: MarketCategory] {
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The category a source named, matched loosely (`Games`, `games`, a missing
    /// value all end up somewhere sensible).
    static func of(_ raw: String?) -> MarketCategory {
        let key = (raw ?? "").lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: "--", with: "-")
        return byID[key] ?? byID["other"]!
    }
}

/// The marketplace: every app in every configured source, browsable by category
/// the way an App Store is, with one-tap installation.
///
/// Pushed from Tools, so it takes the whole screen; the sidebar is its left
/// menu and the grid is the store itself.
struct MarketplaceView: View {
    @EnvironmentObject private var engine: Engine
    /// Watched so a change in Settings updates the list immediately.
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var router = MarketplaceRouter.shared
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var store: SourceStore

    /// The orders the list can be read in.
    enum SortOrder: String, CaseIterable, Identifiable {
        case name, newest, oldest, size

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name:   return L("Name")
            case .newest: return L("Newest")
            case .oldest: return L("Oldest")
            case .size:   return L("Size")
            }
        }

        var icon: String {
            switch self {
            case .name:   return "textformat.abc"
            case .newest: return "calendar.badge.clock"
            case .oldest: return "calendar"
            case .size:   return "arrow.up.arrow.down.square"
            }
        }
    }

    /// What the right-hand side is showing.
    enum Filter: Hashable {
        case all
        /// Anything published in the last fortnight, newest first.
        case recent
        case featured
        case category(String)
        case source(String)
    }

    @State private var filter: Filter? = .all
    @State private var query = ""
    /// What the list draws, rebuilt from the store's entries when they change.
    @State private var visibleApps: [MarketEntry] = []
    @State private var categoryCounts: [String: Int] = [:]
    @State private var featuredKeys: Set<String> = []
    @State private var featuredCount = 0
    /// The store revision the memoised list was built from.
    @State private var builtRevision = -1
    /// How the list is ordered. Applies to every view, including a source's own
    /// shelf, so the same list can be read newest-first or alphabetically.
    @State private var sort: SortOrder = SortOrder(rawValue: AppSettings.shared.marketplaceSort) ?? .name
    @State private var selected: MarketEntry?
    @State private var showAdd = false
    @State private var showManageSources = false
    /// The downloads library sheet, opened from the search bar's trailing icon.
    @State private var showDownloads = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Everything the rail used to hold, along the top: a sideways
                // list is where a phone's thumb already is, and it leaves the
                // full width for the apps underneath.
                topBar
                content
            }
            .background(AppBackground())
            .sheet(item: $selected) { app in
                NavigationStack {
                    MergerAppView(app: app)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L("Done")) { selected = nil }
                            }
                        }
                }
            }
            .sheet(isPresented: $showAdd) { AddSourceSheet(store: store) }
            .sheet(isPresented: $showManageSources) { SourceManagerView(store: store) }
            .sheet(isPresented: $showDownloads) { DownloadsLibraryView() }
            .onAppear {
                store.load()
                syncFromStore()
                // A search sent from My Apps: show everything, and type it in.
                if let wanted = router.pendingSearch {
                    router.pendingSearch = nil
                    query = wanted
                    if router.showAllSources { filter = .all }
                    router.showAllSources = false
                }
            }
            .onChange(of: store.revision) { _, _ in syncFromStore() }
            .onChange(of: filter) { _, _ in refreshVisible() }
            .onChange(of: query) { _, _ in refreshVisible() }
            .onChange(of: sort) { _, _ in
                AppSettings.shared.marketplaceSort = sort.rawValue
                refreshVisible()
            }
            // Changing the setting in Settings must show up here straight away.
            .onChange(of: settings.showNonDirectEntries) { _, _ in refreshVisible() }
            // An install takes over the Install tab, so the app's page closes
            // itself rather than sitting over the run's progress.
            .onChange(of: engine.isRunning) { _, running in
                if running { selected = nil }
            }
        }
    }

    // MARK: The top of the screen

    /// Three things and nothing else: all apps, a filter box, and the sources
    /// manager. Sorting moved into the filter box, where it belongs — it's a
    /// view option, not a place to look.
    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("Marketplace"))
                    .font(.title2.weight(.bold))
                Text(visibleApps.count == 1 ? L("1 app") : L("%ld apps", visibleApps.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    showManageSources = true
                } label: {
                    Label(L("Sources"), systemImage: "shippingbox")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Manage sources"))
            }

            HStack(spacing: 8) {
                // All apps: the unfiltered list, one tap from anywhere.
                Button {
                    query = ""
                    filter = .all
                } label: {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isShowingAll ? AnyShapeStyle(Theme.brand)
                                               : AnyShapeStyle(Color.white.opacity(0.06))))
                        .foregroundStyle(isShowingAll ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("All apps"))

                filterBox
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var isShowingAll: Bool {
        (filter ?? .all) == .all && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One field that filters: typing searches, and the menu beside it picks
    /// where to search — every source, one source, a category, featured — and
    /// how to order the result.
    private var filterBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Menu {
                Section(L("Show")) {
                    Button { filter = .all } label: {
                        Label(L("Every source"), systemImage: marker((filter ?? .all) == .all))
                    }
                    Button {
                        filter = .recent
                        sort = .newest
                    } label: {
                        Label(L("New releases (last 14 days)"), systemImage: marker(isFilter(.recent)))
                    }
                    if featuredCount > 0 {
                        Button { filter = .featured } label: {
                            Label(L("Featured (%ld)", featuredCount),
                                  systemImage: marker(isFilter(.featured)))
                        }
                    }
                    let categories = MarketCategory.all.filter { (categoryCounts[$0.id] ?? 0) > 0 }
                    if !categories.isEmpty {
                        Menu {
                            ForEach(categories) { category in
                                Button {
                                    filter = .category(category.id)
                                } label: {
                                    Label("\(category.title) (\(categoryCounts[category.id] ?? 0))",
                                          systemImage: marker(isCategory(category.id)))
                                }
                            }
                        } label: {
                            Label(isCategoryActive ? L("Category: %@", activeLabel) : L("Category"),
                                  systemImage: "square.grid.2x2")
                        }
                    }
                }
                Section(L("Source")) {
                    ForEach(store.sources) { loaded in
                        Button {
                            filter = .source(loaded.id)
                        } label: {
                            Label("\(loaded.name.isEmpty ? (loaded.url.host ?? L("Source")) : loaded.name) (\(store.count(for: loaded.id)))",
                                  systemImage: marker(isSource(loaded.id)))
                        }
                    }
                }
                Section(L("Sort")) {
                    ForEach(SortOrder.allCases) { order in
                        Button { sort = order } label: {
                            Label(order.title, systemImage: marker(sort == order))
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent2)
                    .frame(width: 28, height: 28)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1, height: 18)

            // The downloads library: what is already on disk, with the choice to
            // configure a build before installing it.
            Button { showDownloads = true } label: {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent2)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Downloads"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.06)))
    }

    /// A checkmark for the active choice, an empty slot for the rest.
    private func marker(_ active: Bool) -> String {
        active ? "checkmark.circle.fill" : "circle"
    }

    private func isFilter(_ value: Filter) -> Bool { (filter ?? .all) == value }

    private func isSource(_ id: String) -> Bool {
        if case .source(let current) = filter ?? .all { return current == id }
        return false
    }

    private func isCategory(_ id: String) -> Bool {
        if case .category(let current) = filter ?? .all { return current == id }
        return false
    }

    private var isCategoryActive: Bool {
        if case .category = filter ?? .all { return true }
        return false
    }

    private var activeLabel: String {
        if case .category(let id) = filter ?? .all {
            return MarketCategory.all.first { $0.id == id }?.title ?? L("Category")
        }
        return L("Category")
    }

    /// What the field says it searches, which follows the filter.
    private var placeholder: String {
        switch filter ?? .all {
        case .all:              return L("Filter apps")
        case .recent:           return L("Filter new releases")
        case .featured:         return L("Filter featured")
        case .category(let id): return L("Filter %@", MarketCategory.all.first { $0.id == id }?.title ?? L("apps"))
        case .source(let id):
            let name = store.sources.first { $0.id == id }?.name ?? L("this source")
            return L("Filter %@", name)
        }
    }

    // MARK: The grid

    private var content: some View {
        ScrollView {
            // Lazy: a source can list hundreds of apps, and only the visible
            // cards should exist.
            LazyVStack(alignment: .leading, spacing: 18) {
                if visibleApps.isEmpty {
                    emptyState
                } else {
                    // Compact rows rather than a grid of cards: more apps per
                    // screen, and the install button sits on the row.
                    LazyVStack(spacing: 8) {
                        ForEach(visibleApps) { app in
                            HStack(spacing: 10) {
                                Button {
                                    selected = app
                                } label: {
                                    ListingRow(app: app)
                                }
                                .buttonStyle(.plain)

                                // One tap installs the newest; the menu offers
                                // every version the sources carry.
                                Button {
                                    install(app)
                                } label: {
                                    Image(systemName: app.latest?.direct == false
                                          ? "arrow.up.forward.app" : "arrow.down.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Theme.accent2)
                                }
                                .buttonStyle(.plain)
                                .disabled(app.latest?.link == nil || engine.isRunning)

                                // Always present, so every row's card is the same
                                // length: a row with one release just has a
                                // disabled chevron instead of a gap.
                                Menu {
                                    ForEach(app.versions) { version in
                                        Button {
                                            install(app, version: version)
                                        } label: {
                                            Text(versionLabel(version))
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down.circle")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(app.versions.count <= 1 || app.latest?.link == nil)
                            }
                            .padding(.trailing, 2)
                            .contextMenu {
                                Button {
                                    install(app)
                                } label: {
                                    Label(L("Download to Install"), systemImage: "square.and.arrow.down")
                                }
                                Button {
                                    if let url = app.latest?.link {
                                        InstallQueue.shared.add(name: app.name, url: url,
                                                                bundleID: app.id)
                                        Haptics.tap()
                                    }
                                } label: {
                                    Label(L("Add to install queue"), systemImage: "text.badge.plus")
                                }
                                ForEach(app.versions) { version in
                                    let title: String = L("Install %@", versionLabel(version))
                                    Button {
                                        install(app, version: version)
                                    } label: {
                                        Label(title, systemImage: "clock.arrow.circlepath")
                                    }
                                }
                                Divider()
                                Button {
                                    selected = app
                                } label: {
                                    Label(L("Details"), systemImage: "info.circle")
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await store.refreshAll() }
    }


    private var emptyState: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                if store.sources.isEmpty {
                    Text(L("No sources yet"))
                        .font(.headline)
                    Text(L("Add an AltStore source to browse and install its apps from here."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(L("Add a source")) { showAdd = true }
                        .buttonStyle(PrimaryButtonStyle())
                } else if store.sources.allSatisfy({ !$0.hasIndex }) {
                    Text(L("Loading…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView()
                } else if case .source(let id) = filter ?? .all,
                          let loaded = store.sources.first(where: { $0.id == id }),
                          let error = loaded.error {
                    Text(L("%@ didn't load", loaded.name))
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await store.refresh(id) }
                    } label: {
                        Label(L("Try again"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                } else if !query.isEmpty {
                    Text(L("No app matches “%@”.", query))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("Nothing here yet"))
                        .font(.headline)
                    Text(L("This part of the marketplace has no apps in it."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Data


    /// Rebuilds the memoised lists from the store. The store already merged the
    /// sources; this only counts and filters.
    private func syncFromStore() {
        guard store.revision != builtRevision else { return }
        builtRevision = store.revision
        featuredKeys = store.featuredKeys
        var counts: [String: Int] = [:]
        for entry in store.entries { counts[MarketCategory.of(entry.category).id, default: 0] += 1 }
        categoryCounts = counts
        featuredCount = featuredKeys.isEmpty ? 0 : store.entries.reduce(0) {
            $0 + (featuredKeys.contains($1.id) ? 1 : 0)
        }
        refreshVisible()
    }

    /// Applies the filter, the search field and the sort — once per change, not
    /// once per layout pass.
    private func refreshVisible() {
        var list = store.entries
        switch filter ?? .all {
        case .all:
            break
        case .recent:
            let cutoff = Date().addingTimeInterval(-14 * 86_400)
            list = list.filter { ($0.latest?.date ?? .distantPast) > cutoff }
        case .featured:
            list = list.filter { featuredKeys.contains($0.id) }
        case .category(let id):
            list = list.filter { MarketCategory.of($0.category).id == id }
        case .source(let id):
            list = list.filter { entry in entry.versions.contains { $0.sourceID == id } }
        }
        if !AppSettings.shared.showNonDirectEntries {
            // Entries whose every release leads to another app (a Telegram post,
            // say) are what this hides: the list is then only what installs here.
            list = list.filter { entry in entry.versions.contains { $0.direct } }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || ($0.developer ?? "").localizedCaseInsensitiveContains(trimmed)
                    || ($0.subtitle ?? "").localizedCaseInsensitiveContains(trimmed)
                    || $0.id.localizedCaseInsensitiveContains(trimmed)
            }
        }
        visibleApps = sorted(list)
    }

    private func sorted(_ list: [MarketEntry]) -> [MarketEntry] {
        switch sort {
        case .name:
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .newest:
            return list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .oldest:
            return list.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        case .size:
            // Largest first: the size worth knowing about is the big one.
            return list.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        }
    }

    /// Installs the chosen release of an app (or the newest) without opening its
    /// page first.
    /// "1.2.3 · 3 Feb 2026", as the version menus show a release.
    private func versionLabel(_ version: MarketEntry.Version) -> String {
        var parts = [version.version ?? L("unknown")]
        if let date = version.date {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if !version.direct { parts.append(L("in Telegram")) }
        return parts.joined(separator: " · ")
    }

    /// Hands a release to the install menu instead of installing it: the app can
    /// be renamed, given capabilities or tweaks, or simply looked at first.
    private func install(_ app: MarketEntry, version: MarketEntry.Version? = nil) {
        guard let picked = app.release(version), let url = picked.link else { return }
        engine.prepareLinkedIPA(url)
    }
}

/// One app's page, assembled from every source that carries it.
///
/// The marketplace merges an app's copies so it's listed once; this is what
/// opens when one is tapped, with the union of its releases and a picker to
/// choose which one to install.
struct MergerAppView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var engine: Engine
    let app: MarketEntry

    @State private var chosen: MarketEntry.Version?
    @State private var showVersions = false

    private var picked: MarketEntry.Version? { app.release(chosen) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                hero
                if let description = app.subtitle, !description.isEmpty {
                    PanelCard {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !app.screenshotURLs.isEmpty { screenshotsCard }
                releaseCard
                if let notes = app.notes, !notes.isEmpty, notes != app.subtitle { notesCard(notes) }
                sourcesCard
                installCard
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(spacing: 12) {
            SourceIcon(url: app.iconURL, side: 92, fallback: "app.fill", corner: 22)
                .shadow(color: Theme.glow, radius: 18, x: 0, y: 10)
            VStack(spacing: 4) {
                Text(app.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                if let developer = app.developer, !developer.isEmpty {
                    Text(developer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(app.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            let category = MarketCategory.of(app.category)
            StatusPill(text: category.title, systemImage: category.icon, color: Theme.accent2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// What's installed on this device, and whether the picked release is newer.
    /// Read from the cached inventory, so it costs nothing.
    private var installedStatus: (version: String?, newer: Bool)? {
        guard let cached = SideloadedAppsManager.cachedInventory() else { return nil }
        let apps = cached.apps.compactMap { SideloadedApp(plist: $0, kinds: [.sideloaded, .testFlight]) }
        guard let installed = apps.first(where: { $0.bundleID == app.id }) else { return nil }
        let newest = app.latest?.version ?? ""
        let newer = (installed.version ?? "0").compare(newest, options: .numeric) == .orderedAscending
        return (installed.version, newer)
    }

    /// The source's own screenshots, side by side and paging. Only what it
    /// publishes — nothing is fetched from the App Store.
    private var screenshotsCard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(app.screenshotURLs, id: \.absoluteString) { url in
                    SourceImage(url: url, side: 220, corner: 14)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func notesCard(_ notes: String) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("What's new"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var releaseCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Release"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showVersions = true
                    } label: {
                        Label(picked?.version ?? L("Newest"), systemImage: "chevron.up.chevron.down")
                            .font(.subheadline.weight(.semibold))
                    }
                    .confirmationDialog(L("Choose a version"), isPresented: $showVersions) {
                        ForEach(app.versions) { version in
                            Button(label(version)) { chosen = version }
                        }
                        Button(L("Cancel"), role: .cancel) {}
                    }
                }
                if let installed = installedStatus {
                    Label(installed.newer
                          ? L("Installed %@ — this release is newer", installed.version ?? "?")
                          : L("Installed %@", installed.version ?? "?"),
                          systemImage: installed.newer ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(installed.newer ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.green))
                }
                if let picked {
                    VStack(alignment: .leading, spacing: 8) {
                        if let date = picked.date {
                            row(L("Released"), date.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let size = picked.size, size > 0 {
                            row(L("Size"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                        if let minOS = picked.minOS {
                            row(L("Needs iOS"), minOS, warn: picked.needsNewerOS)
                        }
                        row(L("From"), picked.sourceName)
                    }
                }
            }
        }
    }

    /// Every source carrying this app, and how many of its versions each has.
    private var sourcesCard: some View {
        let grouped = Dictionary(grouping: app.versions, by: \.sourceID)
        return PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("In your sources"))
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(grouped.keys), id: \.self) { id in
                    if let versions = grouped[id], let name = versions.first?.sourceName {
                        HStack {
                            Text(name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(L("%ld versions", versions.count))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var installCard: some View {
        PanelCard {
            VStack(spacing: 12) {
                Button {
                    guard let picked, let url = picked.link else { return }
                    if picked.direct {
                        engine.prepareLinkedIPA(url)
                    } else {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label(picked?.direct == false
                          ? L("Open in Telegram")
                          : L("Download %@ to Install", picked?.version ?? L("newest")),
                          systemImage: picked?.direct == false
                          ? "arrow.up.forward.app" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(picked?.link == nil || picked?.needsNewerOS == true
                          || engine.isRunning || engine.isImportingIPA)

                Text(picked?.direct == false
                     ? L("Telegram keeps its files behind the app — this opens the post there to download. Bring the .ipa back here, or use a source that links the file directly.")
                     : L("Downloads the .ipa, signs it with your Apple ID and installs it — the same run as any other build."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func label(_ version: MarketEntry.Version) -> String {
        var parts = [version.version ?? L("unknown")]
        if let date = version.date {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(AnyShapeStyle(warn ? Color.orange : Color.primary))
            Spacer(minLength: 0)
        }
    }
}

/// One app in the list: icon, name, developer and category, with the newest
/// version on the right. Deliberately small — the marketplace is for finding
/// and installing, and the app's own page has the rest.
private struct ListingRow: View {
    let app: MarketEntry

    var body: some View {
        HStack(spacing: 12) {
            SourceIcon(url: app.iconURL, side: 44, fallback: "app.fill", corner: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(app.latest?.version ?? "")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if app.versions.count > 1 {
                    Text(L("%ld versions", app.versions.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let size = app.size, size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    /// "Developer · Category", with whatever of the two the source gave.
    private var subtitle: String {
        let category = MarketCategory.of(app.category).title
        switch (app.developer?.isEmpty == false, category.isEmpty) {
        case (true, false):  return "\(app.developer!) · \(category)"
        case (true, true):   return app.developer!
        case (false, false): return category
        default:             return app.latest?.sourceName ?? ""
        }
    }
}
