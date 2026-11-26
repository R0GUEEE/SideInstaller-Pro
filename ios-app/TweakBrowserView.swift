import SwiftUI

/// Browses Sileo/Cydia repositories and adds a package's library to the app
/// configuration, which is the same thing as picking the `.deb` from Files —
/// with the index read for you, so a tweak can be found by name.
///
/// Every package here is fetched over HTTPS the way an apt client would; the
/// `.deb` is checked against the index's SHA-256 when it publishes one, and
/// unpacked by `AppConfigStore.addTweaks`, which is the one place that decides
/// what a package contributes.
struct TweakBrowserView: View {
    /// The configuration the added tweaks land in. Passed in, because that's
    /// the store the page that opened this one is showing.
    @ObservedObject var store: AppConfigStore

    @ObservedObject private var repos = TweakRepoStore.shared
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// Restricts the list to one repository; nil is all of them.
    @State private var scope: UUID?
    @State private var adding: String?
    @State private var note: String?
    @State private var detail: RepoPackage?
    @State private var newRepo = ""
    @State private var addingRepo = false
    @State private var pendingRemove: TweakRepository?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    header.cascadeItem(0)
                    searchCard.cascadeItem(1)
                    if let note {
                        noteCard(note).cascadeItem(2)
                    }
                    if !repos.repos.isEmpty {
                        scopeRow.cascadeItem(2)
                    }
                    if isBrowsing {
                        results.cascadeItem(3)
                    } else {
                        ForEach(Array(repos.repos.enumerated()), id: \.element.id) { index, repo in
                            repositoryCard(repo).cascadeItem(min(index + 2, 6))
                        }
                        addCard.cascadeItem(min(repos.repos.count + 2, 7))
                        explainer.cascadeItem(min(repos.repos.count + 3, 8))
                    }
                }
                .padding(20)
                .pageColumn()
            }
            .scrollDismissesKeyboard(.immediately)
            .background(AppBackground())
            .navigationTitle(L("Tweak browser"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await repos.refreshAll() }
                    } label: {
                        Label(L("Refresh"), systemImage: "arrow.clockwise")
                    }
                    .disabled(repos.busy.count == repos.repos.count && !repos.repos.isEmpty)
                }
            }
            .task { await repos.refreshIfStale() }
            .sheet(item: $detail) { package in
                TweakPackageDetail(package: package,
                                   repoName: repos.repo(package.repoID)?.name ?? "",
                                   store: store,
                                   installedVersion: installed(package)?.version)
            }
            .confirmationDialog(L("Remove this repository?"),
                                isPresented: Binding(get: { pendingRemove != nil },
                                                     set: { if !$0 { pendingRemove = nil } }),
                                presenting: pendingRemove) { repo in
                Button(L("Remove %@", repo.name), role: .destructive) {
                    repos.remove(repo.id)
                    if scope == repo.id { scope = nil }
                    pendingRemove = nil
                    Haptics.destructive()
                }
                Button(L("Cancel"), role: .cancel) { pendingRemove = nil }
            } message: { repo in
                Text(L("%@ is taken off this list. No tweak already in the configuration changes.", repo.name))
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        BrandHeader(icon: "syringe.fill", title: L("Tweak browser")) {
            if !repos.repos.isEmpty {
                StatusPill(text: L("%d repositories", repos.repos.count),
                           systemImage: "shippingbox.fill", color: Theme.accent2)
            }
        }
    }

    private var searchCard: some View {
        PanelCard {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("Search packages"), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .fieldBackground()
        }
    }

    private func noteCard(_ text: String) -> some View {
        PanelCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent2)
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Titles of the repositories, as filters, so a search can be narrowed to
    /// the one being looked at.
    private var scopeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(L("All"), selected: scope == nil) { scope = nil }
                ForEach(repos.repos) { repo in
                    chip(repo.name, selected: scope == repo.id) { scope = repo.id }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : .secondary)
                .background(Capsule().fill(selected ? Theme.accent : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func repositoryCard(_ repo: TweakRepository) -> some View {
        PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "shippingbox.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.accent2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.name)
                                .font(.headline)
                                .lineLimit(1)
                            Text(repo.url)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        if repos.busy.contains(repo.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                Task { await repos.refresh(repo) }
                            } label: {
                                Image(systemName: "arrow.clockwise").font(.footnote)
                            }
                            .buttonStyle(.borderless)
                            Button {
                                pendingRemove = repo
                            } label: {
                                Image(systemName: "trash").font(.footnote)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(repo.count == 0
                             ? L("Not read yet")
                             : L("%d packages", repo.count))
                        if let updated = repo.updated {
                            Text("·")
                            Text(updated.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let error = repos.errors[repo.id] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        query = ""
                        scope = repo.id
                    } label: {
                        Label(L("Browse %@", repo.name), systemImage: "chevron.right")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(repo.count == 0)
                }
        }
    }

    private var addCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Add a repository"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField(L("https://repo.example.com"), text: $newRepo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .fieldBackground()
                    Button {
                        addRepository()
                    } label: {
                        if addingRepo {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L("Add"))
                                .font(.footnote.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(addingRepo || newRepo.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(L("Any Sileo or Cydia repository works: paste the address you'd give it, and its Packages index is read for packages built for iPhone."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var explainer: some View {
        Text(L("A package added here is the same as a .deb picked from Files: its libraries are taken out and loaded by the app when it's installed. Injectable tweaks are built for arm64; a rootless package works either way, since only the .dylib is used. The package is downloaded once, when you add it."))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Results

    private var isBrowsing: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || scope != nil
    }

    private var matches: [RepoPackage] {
        let ids = scope.map { [$0] } ?? Array(repos.packages.keys)
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list = ids.flatMap { repos.packages[$0] ?? [] }
        if !term.isEmpty {
            list = list.filter { package in
                package.name.lowercased().contains(term)
                    || package.identifier.lowercased().contains(term)
                    || package.summary.lowercased().contains(term)
                    || package.author.lowercased().contains(term)
                    || package.section.lowercased().contains(term)
            }
        }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var results: some View {
        let all = matches
        let shown = Array(all.prefix(200))
        return PanelCard {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("%d results", all.count))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if scope == nil && repos.repos.count > 1 {
                        Text(L("across every repository"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if shown.isEmpty {
                    Text(L("No package matches that. Try the package's name, its identifier, or the developer."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(shown) { package in
                    packageRow(package)
                    Divider().opacity(0.15)
                }
                if all.count > shown.count {
                    Text(L("Showing the first %d of %d. Add more of the name to narrow it down.", shown.count, all.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func packageRow(_ package: RepoPackage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon(package)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !package.version.isEmpty {
                        Text(package.version)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if let line = package.summary.split(separator: "\n").first, !line.isEmpty {
                    Text(String(line))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if !package.section.isEmpty { Text(package.section) }
                    if scope == nil, let repo = repos.repo(package.repoID) {
                        if !package.section.isEmpty { Text("·") }
                        Text(repo.name)
                    }
                    if !package.sizeText.isEmpty {
                        Text("·")
                        Text(package.sizeText)
                    }
                    if let current = installed(package)?.version, hasUpdate(package) {
                        Text("·")
                        Text(L("installed %@", current))
                            .foregroundStyle(Theme.accent2)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            addButton(package)
        }
        .contentShape(Rectangle())
        .onTapGesture { detail = package }
    }

    private func icon(_ package: RepoPackage) -> some View {
        Group {
            if let text = package.iconURL, let url = URL(string: text) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholderIcon
                    }
                }
            } else {
                placeholderIcon
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholderIcon: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.accent.opacity(0.16))
            .overlay {
                Image(systemName: "syringe")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent2)
            }
    }

    private func addButton(_ package: RepoPackage) -> some View {
        Group {
            if adding == package.id {
                ProgressView().controlSize(.small)
            } else if hasUpdate(package) {
                Button {
                    add(package)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Update %@", package.name))
            } else if installed(package) != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityLabel(L("Already added"))
            } else {
                Button {
                    add(package)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Add %@", package.name))
            }
        }
        .frame(width: 32)
    }

    // MARK: - Actions

    /// The configuration's copy of a package, if it has one.
    private func installed(_ package: RepoPackage) -> Tweak? {
        store.installedTweak(for: package)
    }

    /// True when the repository's release is newer than the copy the
    /// configuration holds — the one thing a browser can know that a file
    /// picker can't.
    private func hasUpdate(_ package: RepoPackage) -> Bool {
        guard let current = installed(package)?.version else { return false }
        return TweakRepoParser.isNewer(package.version, than: current)
    }

    @MainActor
    private func add(_ package: RepoPackage) {
        guard adding == nil else { return }
        let previous = installed(package)?.version
        adding = package.id
        Task {
            defer { adding = nil }
            do {
                let added = try await TweakPackageInstaller.add(package, to: store)
                if added {
                    Haptics.success()
                    if let previous {
                        show(L("Updated %@ from %@ to %@.", package.name, previous, package.version))
                    } else {
                        show(L("Added %@ to the app configuration.", package.name))
                    }
                } else {
                    Haptics.warning()
                    show(L("%@ was downloaded, but nothing in it can be injected.", package.name))
                }
            } catch {
                Haptics.warning()
                show(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func addRepository() {
        let text = newRepo
        guard !addingRepo, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        addingRepo = true
        Task {
            defer { addingRepo = false }
            do {
                let repo = try await repos.addRepo(text)
                newRepo = ""
                scope = repo.id
                if let error = repos.errors[repo.id] {
                    Haptics.warning()
                    show(error)
                } else {
                    Haptics.success()
                    show(L("Added %@ — %d packages.", repo.name, repo.count))
                }
            } catch {
                Haptics.warning()
                show(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func show(_ text: String) {
        note = text
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if note == text { note = nil }
        }
    }
}

/// One package, with everything the index says about it and the button that
/// adds it to the configuration.
private struct TweakPackageDetail: View {
    let package: RepoPackage
    let repoName: String
    @ObservedObject var store: AppConfigStore
    /// The version in the configuration when the sheet opens, if there is one.
    let installedVersion: String?

    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    @State private var adding = false
    @State private var added = false
    @State private var note: String?

    private var isInConfig: Bool { added || (installedVersion != nil && !canUpdate) }

    /// A newer release than the copy in the configuration is what the button is
    /// for, when there is one.
    private var canUpdate: Bool {
        guard let installedVersion else { return false }
        return TweakRepoParser.isNewer(package.version, than: installedVersion)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if let note {
                        PanelCard {
                            Text(note)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !package.summary.isEmpty {
                        PanelCard {
                            Text(package.summary)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    facts
                    if !package.depends.isEmpty {
                        PanelCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L("Depends"))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(package.depends)
                                    .font(.caption.monospaced())
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(L("A dependency naming ElleKit, Substrate, libhooker or Substitute sets which framework the app loads beside this tweak. The rest are not installed: only the library in this package is taken."))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    addButton
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(package.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Group {
                if let text = package.iconURL, let url = URL(string: text) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(package.name)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            if !package.author.isEmpty {
                Text(package.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if !package.version.isEmpty {
                    StatusPill(text: package.version, systemImage: "tag.fill", color: Theme.accent2)
                }
                if !package.architecture.isEmpty {
                    StatusPill(text: package.architecture.replacingOccurrences(of: "iphoneos-", with: ""),
                               systemImage: "cpu", color: package.isModern ? .green : .orange)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.accent.opacity(0.16))
            .overlay {
                Image(systemName: "syringe")
                    .font(.title2)
                    .foregroundStyle(Theme.accent2)
            }
    }

    private var facts: some View {
        PanelCard {
            VStack(spacing: 8) {
                fact(L("Package"), package.identifier)
                if !repoName.isEmpty { fact(L("Repository"), repoName) }
                if !package.section.isEmpty { fact(L("Section"), package.section) }
                if !package.sizeText.isEmpty { fact(L("Download"), package.sizeText) }
                if let installedVersion, !added {
                    fact(L("Installed"), installedVersion)
                }
            }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttonTitle: String {
        if isInConfig { return L("In the configuration") }
        if canUpdate, let installedVersion {
            return L("Update %@ to %@", installedVersion, package.version)
        }
        return L("Add to the configuration")
    }

    private var addButton: some View {
        Button {
            add()
        } label: {
            HStack(spacing: 8) {
                if adding {
                    ProgressView().controlSize(.small).tint(.white)
                } else if isInConfig {
                    Image(systemName: "checkmark.circle.fill")
                } else if canUpdate {
                    Image(systemName: "arrow.up.circle.fill")
                } else {
                    Image(systemName: "plus.circle.fill")
                }
                Text(buttonTitle)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isInConfig ? Color.green.opacity(0.18) : Theme.accent))
            .foregroundStyle(isInConfig ? Color.green : Color.white)
        }
        .buttonStyle(.plain)
        .disabled(adding || isInConfig)
    }

    @MainActor
    private func add() {
        guard !adding else { return }
        let previous = installedVersion
        adding = true
        Task {
            defer { adding = false }
            do {
                let ok = try await TweakPackageInstaller.add(package, to: store)
                if ok, let previous, canUpdate {
                    added = true
                    Haptics.success()
                    note = L("Updated from %@. Close this page and it's listed under Tweaks & injectors, ready for the next install.", previous)
                } else if ok {
                    added = true
                    Haptics.success()
                    note = L("Added. Close this page and it's listed under Tweaks & injectors, ready for the next install.")
                } else {
                    note = L("The package downloaded, but it carries no library SideInstaller can inject.")
                    Haptics.warning()
                }
            } catch {
                note = error.localizedDescription
                Haptics.warning()
            }
        }
    }
}
