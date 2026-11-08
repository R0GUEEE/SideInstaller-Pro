import SwiftUI

/// A Tools page, reachable either by a push or by a sheet.
///
/// The page is a menu: the case carries what to open, and `ToolsView` builds
/// the destination, so a row's title, its status line and where it goes all
/// live in one place.
enum ToolDestination: String, Identifiable, Hashable {
    case device, location, keepAlive
    case certificates, entitlements, pairing, sideBySide
    case history, storedBuilds, appFiles, injectedLibraries, inspectIPA
    case sources, tweakBrowser, tweakLibrary
    case settings, report, about

    var id: String { rawValue }

    /// Pages that own their own `NavigationStack` are presented as sheets;
    /// pushing one would nest a second stack inside the first.
    var presentsAsSheet: Bool {
        switch self {
        case .sources, .settings, .report, .about: return true
        default:                        return false
        }
    }
}

/// One row of the Tools menu.
struct ToolEntry: Identifiable {
    let id: String
    let title: String
    /// What the page holds or what state it's in, shown under the title.
    var detail: String? = nil
    /// A warning colour for a detail that needs attention (a certificate about
    /// to expire, say).
    var detailTint: Color? = nil
    var icon: String? = nil
    /// Brand art, used instead of an SF Symbol when a page has a logo.
    var image: String? = nil
    var beta = false
    var destination: ToolDestination

    /// Everything the search field matches against.
    var haystack: String {
        (title + " " + (detail ?? "")).lowercased()
    }
}

/// A titled group of rows, drawn as one card so the page reads as a menu of
/// sections rather than a stack of unrelated panels.
struct ToolsSectionCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
                content()
            }
        }
    }
}

/// One menu row: glyph, name, live status, chevron.
struct ToolRow: View {
    var entry: ToolEntry

    var body: some View {
        HStack(spacing: 12) {
            glyph
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if entry.beta { BetaBadge() }
                }
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(entry.detailTint ?? .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var glyph: some View {
        if let image = entry.image {
            Image(image)
                .resizable()
                .scaledToFit()
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.accent.opacity(0.16))
                .overlay {
                    Image(systemName: entry.icon ?? "wrench.and.screwdriver")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent2)
                }
        }
    }
}

/// The Tools tab: every page that isn't an install, grouped by what it's for,
/// each row carrying the state of the thing it opens.
///
/// The rows are data (`ToolEntry`), so the search field, the section headers and
/// the status lines all come from one list — a page can't be added without
/// saying what it's for and what it currently holds.
struct ToolsView: View {
    /// Observed so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer
    /// Watched for a `sideinstaller://source` link, which opens the add sheet,
    /// and read for the device's own summary line.
    @EnvironmentObject private var engine: Engine
    /// The build's version, for the About row.
    @EnvironmentObject private var updateChecker: UpdateChecker
    /// Passed in (owned by `RootView`) so pages keep their state across tabs.
    @ObservedObject var pairingManager: PairingManager
    @ObservedObject var certManager: CertManager
    @ObservedObject var locationManager: LocationManager
    @ObservedObject var entitlementsManager: EntitlementsManager
    @ObservedObject var appsManager: SideloadedAppsManager
    @ObservedObject var sideBySideManager: SideBySideManager
    @ObservedObject var sourceStore: SourceStore

    /// The two stores whose contents are a row's status line.
    @ObservedObject private var tweakRepos = TweakRepoStore.shared
    /// The keep-alive's state, for its row's status line.
    @ObservedObject private var keeper = BackgroundKeeper.shared
    /// The local tweak library, for the storage row's count.
    @ObservedObject private var tweakLibrary = TweakLibrary.shared
    @ObservedObject private var history = InstallHistory.shared

    /// The sheet a row opens, when the page it opens owns its own stack.
    @State private var sheet: ToolDestination?
    /// The search field's text; empty shows every section.
    @State private var query = ""
    /// What the stored-builds row says. Read on appear, not in a body: it's a
    /// directory listing.
    @State private var storedCount = 0
    @State private var storedBytes: Int64 = 0
    /// The signing certificate's state, formatted once instead of on every
    /// redraw — the row is drawn before any of that work can be seen.
    @State private var certificate: (text: String, tint: Color?) = (L("Reading…"), nil)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header.cascadeItem(0)
                    searchField.cascadeItem(1)

                    if visibleSections.isEmpty {
                        noMatches.cascadeItem(2)
                    } else {
                        ForEach(Array(visibleSections.enumerated()), id: \.element.id) { index, section in
                            ToolsSectionCard(title: section.title) {
                                VStack(spacing: 0) {
                                    ForEach(Array(section.entries.enumerated()), id: \.element.id) { position, entry in
                                        if position > 0 {
                                            Divider()
                                                .opacity(0.12)
                                                .padding(.leading, 44)
                                        }
                                        row(entry)
                                    }
                                }
                            }
                            .cascadeItem(min(index + 2, 6))
                        }
                    }
                }
                .padding(20)
                .pageColumn()
            }
            // Still unless the sections don't all fit on the screen.
            .scrollBounceBehavior(.basedOnSize)
            .navigationBarTitleDisplayMode(.inline)
            .background(AppBackground())
            .sheet(item: $sheet) { destination in page(destination) }
            // A link's source arrives here, prefilled and ready to add.
            .sheet(isPresented: Binding(get: { engine.sourceToAdd != nil },
                                        set: { if !$0 { engine.sourceToAdd = nil } })) {
                AddSourceSheet(store: sourceStore,
                               prefilled: engine.sourceToAdd?.absoluteString ?? "")
            }
            .onAppear {
                refreshCertificate()
                refreshStored()
            }
            .onChange(of: certManager.certs.count) { _, _ in refreshCertificate() }
            .onChange(of: certManager.isSignedIn) { _, _ in refreshCertificate() }
        }
    }

    // MARK: Header

    private var header: some View {
        BrandHeader(icon: "wrench.and.screwdriver.fill", title: L("Tools"), compact: true,
                    trailingActions: AnyView(settingsButton)) {
            StatusPill(text: L("%d pages", allEntries.count),
                       systemImage: "square.grid.2x2.fill",
                       color: Theme.accent2)
        }
    }

    /// Settings sits beside the page title: the header row has room, and a
    /// toolbar band above it was pure empty space.
    private var settingsButton: some View {
        Button { sheet = .settings } label: {
            Image(systemName: "gearshape.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent2)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Settings"))
    }

    private var searchField: some View {
        PanelCard {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("Search tools"), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .fieldBackground()
        }
    }

    private var noMatches: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Nothing matches that"))
                    .font(.headline)
                Text(L("Every page here is listed above — try a shorter word, like “cert”, “ipa” or “log”."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: The list

    private struct ToolGroup: Identifiable {
        let id: String
        let title: String
        let entries: [ToolEntry]
    }

    private var allEntries: [ToolEntry] {
        sections.flatMap(\.entries)
    }

    private var visibleSections: [ToolGroup] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return sections }
        return sections.compactMap { section in
            let matches = section.entries.filter { $0.haystack.contains(term) }
            return matches.isEmpty ? nil : ToolGroup(id: section.id, title: section.title, entries: matches)
        }
    }

    private var sections: [ToolGroup] {
        let device: [ToolEntry] = [
            ToolEntry(id: "device",
                      title: L("Device"),
                      detail: engine.deviceSummary ?? L("Model, iOS build and storage"),
                      icon: "iphone.gen3",
                      destination: .device),
            ToolEntry(id: "location",
                      title: L("Location spoofing"),
                      detail: L("Set where this iPhone says it is"),
                      icon: "location.fill",
                      destination: .location),
            ToolEntry(id: "background",
                      title: L("Background"),
                      detail: keeper.isRunning
                            ? L("Running · %@", keeper.mode.title)
                            : L("Keep the app alive with audio or location"),
                      detailTint: keeper.isRunning ? .green : nil,
                      icon: "clock.badge.checkmark",
                      destination: .keepAlive),
        ]
        var signing: [ToolEntry] = [
            ToolEntry(id: "certificates",
                      title: L("Certificates"),
                      detail: certificate.text,
                      detailTint: certificate.tint,
                      image: "CertsLogo",
                      destination: .certificates),
            ToolEntry(id: "entitlements",
                      title: L("Entitlements"),
                      detail: entitlementsManager.apps.isEmpty
                            ? L("What the App IDs are granted")
                            : L("%d app(s)", entitlementsManager.apps.count),
                      image: "EntitlementsLogo",
                      destination: .entitlements),
        ]
        // Only iOS 27+ pairs itself; older iPhones import the file on Install.
        if Engine.deviceCanSelfPair {
            signing.append(ToolEntry(id: "pairing",
                                     title: L("Pairing"),
                                     detail: engine.importedPairingName.map { L("Using %@", $0) }
                                             ?? L("Automatic"),
                                     image: "PairingLogo",
                                     destination: .pairing))
        }
        signing.append(ToolEntry(id: "sideBySide",
                                 title: L("Side by Side"),
                                 detail: L("Install to a second iPhone"),
                                 image: "SideBySideLogo",
                                 beta: true,
                                 destination: .sideBySide))

        let builds: [ToolEntry] = [
            ToolEntry(id: "history",
                      title: L("Install history"),
                      detail: history.entries.isEmpty
                            ? L("Nothing installed yet")
                            : L("%d build(s) recorded", history.entries.count),
                      icon: "clock.arrow.circlepath",
                      destination: .history),
            ToolEntry(id: "stored",
                      title: L("Stored builds"),
                      detail: storedDetail,
                      icon: "internaldrive.fill",
                      destination: .storedBuilds),
            ToolEntry(id: "appFiles",
                      title: L("App files & storage"),
                      detail: L("Browse accessible app folders and clear data"),
                      icon: "folder.badge.gearshape",
                      destination: .appFiles),
            ToolEntry(id: "injected",
                      title: L("Injected libraries"),
                      detail: L("See, and strip, what a build loads"),
                      icon: "puzzlepiece.extension",
                      destination: .injectedLibraries),
            ToolEntry(id: "inspect",
                      title: L("Inspect .ipa"),
                      detail: L("Identity, signing and compatibility"),
                      icon: "doc.text.magnifyingglass",
                      destination: .inspectIPA),
        ]

        let sources: [ToolEntry] = [
            ToolEntry(id: "sources",
                      title: L("Marketplace sources"),
                      detail: sourceStore.sources.isEmpty
                            ? L("Add a source")
                            : L("%d source(s)", sourceStore.sources.count),
                      icon: "square.stack.3d.up",
                      destination: .sources),
            ToolEntry(id: "tweaks",
                      title: L("Tweak browser"),
                      detail: tweakRepos.repos.isEmpty
                            ? L("Add a repository")
                            : L("%d repository(s)", tweakRepos.repos.count),
                      icon: "syringe",
                      destination: .tweakBrowser),
            ToolEntry(id: "tweakLibrary",
                      title: L("Tweak storage"),
                      detail: tweakLibrary.items.isEmpty
                            ? L("Keep .dylib and .deb files, and bundles of them")
                            : L("%d tweak(s) · %d bundle(s)",
                                tweakLibrary.items.count, tweakLibrary.bundles.count),
                      icon: "tray.full",
                      destination: .tweakLibrary),
        ]

        let help: [ToolEntry] = [
            ToolEntry(id: "report",
                      title: L("Report a problem"),
                      detail: L("Crash logs, the log, and a GitHub issue"),
                      icon: "exclamationmark.bubble",
                      destination: .report),
            ToolEntry(id: "about",
                      title: L("About SideInstaller"),
                      detail: L("Version %@", updateChecker.currentVersion),
                      icon: "info.circle",
                      destination: .about),
        ]

        return [
            ToolGroup(id: "device", title: L("Device"), entries: device),
            ToolGroup(id: "signing", title: L("Signing"), entries: signing),
            ToolGroup(id: "builds", title: L("Apps & builds"), entries: builds),
            ToolGroup(id: "sources", title: L("Sources & tweaks"), entries: sources),
            ToolGroup(id: "help", title: L("Help"), entries: help),
        ]
    }

    // MARK: Status lines

    /// The signing certificate's state, which is the one thing on this page that
    /// changes on its own. Parsed and formatted here, once per change, rather
    /// than inside a body that runs on every keystroke in the search field.
    @MainActor
    private func refreshCertificate() {
        let certs = certManager.certs
        guard !certs.isEmpty else {
            certificate = (L("None yet — sign in to see them"), .orange)
            return
        }
        let signing = certs.first { $0.signing == true } ?? certs[0]
        guard let date = signing.expiresAt else {
            certificate = (L("%d certificate(s)", certs.count), nil)
            return
        }
        let soon = date.timeIntervalSinceNow < 14 * 24 * 60 * 60
        certificate = (date.timeIntervalSinceNow < 0
                       ? L("Expired %@", date.formatted(date: .abbreviated, time: .omitted))
                       : L("Signing certificate expires %@",
                           date.formatted(date: .abbreviated, time: .omitted)),
                       soon ? .orange : nil)
    }

    private var storedDetail: String {
        guard storedCount > 0 else { return L("Copies kept for re-signing") }
        let size = ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file)
        return L("%d build(s) · %@", storedCount, size)
    }

    /// A directory listing, so it's read when the page appears and after a
    /// return from a page that can delete a copy.
    @MainActor
    private func refreshStored() {
        Task {
            let all = await IPACache.load()
            storedCount = all.count
            storedBytes = all.reduce(Int64(0)) { $0 + $1.bytes }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ entry: ToolEntry) -> some View {
        if entry.destination.presentsAsSheet {
            Button { sheet = entry.destination } label: {
                ToolRow(entry: entry)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink { page(entry.destination) } label: {
                ToolRow(entry: entry)
            }
            .buttonStyle(.plain)
        }
    }

    /// The page a row opens. One switch, so the list and the destinations can't
    /// drift apart.
    @ViewBuilder
    private func page(_ destination: ToolDestination) -> some View {
        switch destination {
        case .device:           DeviceInfoView()
        case .location:         LocationView(manager: locationManager)
        case .keepAlive:        BackgroundKeeperView()
        case .certificates:     CertsView(manager: certManager)
        case .entitlements:     EntitlementsView(manager: entitlementsManager)
        case .pairing:          PairingView(manager: pairingManager)
        case .sideBySide:       SideBySideView(manager: sideBySideManager)
        case .history:          InstallHistoryView()
        case .storedBuilds:     IPACacheView()
        case .appFiles:         AppFilesView()
        case .injectedLibraries: TweakManagerView()
        case .inspectIPA:       IPAInspectorView()
        case .sources:          SourceManagerView(store: sourceStore)
        case .tweakBrowser:     TweakBrowserView(store: AppConfigStore.shared)
        case .tweakLibrary:     TweakLibraryView()
        case .settings:         SettingsView()
        case .report:           ReportProblemView()
        case .about:            AboutView(showsDone: true)
        }
    }
}

