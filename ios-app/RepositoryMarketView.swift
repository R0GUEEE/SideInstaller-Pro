import SwiftUI

/// Repositories worth starting with: the big community catalogues that publish
/// AltStore-format JSON, a few stores' own sources, and GitHub release feeds for
/// apps people sideload most.
///
/// Curated rather than scraped — the app ships the list, so it can be trusted
/// and it works offline. Each entry says what kind of source it is, so the
/// marketplace shows its badge.
struct RepositoryDirectory {

    struct Entry: Identifiable {
        let name: String
        let url: String
        let kind: SourceKind
        let store: SourceKind.Store
        /// What it carries, in a line.
        let detail: String
        let category: String

        var id: String { url }
        var icon: URL? {
            guard let host = URL(string: url)?.host else { return nil }
            return URL(string: "https://\(host)/favicon.ico")
        }
    }

    static var all: [Entry] { [
        // Verified 2026-10-28: each returned an AltStore-format document with
        // the app count shown. AltStore Complete is the broadest single
        // catalogue; the store sources are the ones their own teams publish.
        .init(name: "AltStore", url: "https://apps.altstore.io", kind: .altSource, store: .altStore,
              detail: L("AltStore's own catalogue: Delta and the utilities its team publishes."),
              category: L("Official")),
        .init(name: "SideStore", url: "https://sidestore.io/apps.json", kind: .altSource, store: .sideStore,
              detail: L("SideStore's own source."),
              category: L("Official")),
        .init(name: "SideStore Team Picks", url: "https://community-apps.sidestore.io/sidecommunity.json", kind: .altSource, store: .sideStore,
              detail: L("The apps SideStore's community maintains builds of."),
              category: L("Official")),
        .init(name: "BatSign (E-Sign)", url: "https://raw.githubusercontent.com/8yy/BatSign/main/app-repo.json", kind: .altSource, store: .eSign,
              detail: L("BatSign, the signing app — its own source."),
              category: L("Official")),
        .init(name: "App Fair", url: "https://appfair.net/altstore.json", kind: .altSource, store: .other,
              detail: L("The App Fair Project's open-source apps."),
              category: L("Official")),
        .init(name: "Taurine", url: "https://taurine.app/altstore/taurinestore.json", kind: .altSource, store: .other,
              detail: L("Taurine's jailbreak-side tools."),
              category: L("Official")),

        // Large catalogues.
        .init(name: "AltStore Complete", url: "https://quarksources.github.io/altstore-complete.json", kind: .altSource, store: .other,
              detail: L("Quark's combined catalogue — a good first source to browse."),
              category: L("Large catalogues")),
        .init(name: "Quantum Source", url: "https://quarksources.github.io/quantumsource.json", kind: .altSource, store: .other,
              detail: L("Quark's main source, updated often."),
              category: L("Large catalogues")),
        .init(name: "Quantum Source++", url: "https://quarksources.github.io/quantumsource++.json", kind: .altSource, store: .other,
              detail: L("The extended edition of Quantum Source."),
              category: L("Large catalogues")),
        .init(name: "AppTesters IPA Repo", url: "https://repository.apptesters.org", kind: .altSource, store: .other,
              detail: L("Several thousand IPAs, updated as their maintainers publish them."),
              category: L("Large catalogues")),
        .init(name: "CyPwn IPA Library", url: "https://ipa.cypwn.xyz/cypwn.json", kind: .altSource, store: .other,
              detail: L("The CyPwn community's library of decrypted apps."),
              category: L("Large catalogues")),

        // App repositories for one app or a small set.
        .init(name: "UTM", url: "https://alt.getutm.app", kind: .altSource, store: .other,
              detail: L("Virtual machines on iOS — the classic JIT beneficiary."),
              category: L("App repositories")),
        .init(name: "Provenance", url: "https://provenance-emu.com/apps.json", kind: .altSource, store: .other,
              detail: L("The Provenance emulator's own source."),
              category: L("App repositories")),
        .init(name: "iSH", url: "https://ish.app/altstore.json", kind: .altSource, store: .other,
              detail: L("The iSH Linux shell's source."),
              category: L("App repositories")),
        .init(name: "Flycast", url: "https://flyinghead.github.io/flycast-builds/altstore.json", kind: .altSource, store: .other,
              detail: L("Dreamcast emulator builds."),
              category: L("App repositories")),
        .init(name: "Odyssey", url: "https://theodyssey.dev/altstore/odysseysource.json", kind: .altSource, store: .other,
              detail: L("The Odyssey jailbreak's tools."),
              category: L("App repositories")),
        .init(name: "Apollo for Reddit", url: "https://raw.githubusercontent.com/Balackburn/Apollo/refs/heads/main/apps.json", kind: .altSource, store: .other,
              detail: L("The community-patched Apollo build."),
              category: L("App repositories")),
        .init(name: "OatmealDome", url: "https://altstore.oatmealdome.me", kind: .altSource, store: .other,
              detail: L("OatmealDome's tools."),
              category: L("App repositories")),
        .init(name: "Ignited", url: "https://altstore.ignitedemulator.com", kind: .altSource, store: .other,
              detail: L("Ignited emulator builds."),
              category: L("App repositories")),

        // Community sources of a handful of apps each.
        .init(name: "RandomSource", url: "https://randomblock1.com/altstore/apps.json", kind: .altSource, store: .other,
              detail: L("Randomblock1's source."),
              category: L("Community")),
        .init(name: "Burrito's AltStore", url: "https://burritosoftware.github.io/altstore/channels/burritosource.json", kind: .altSource, store: .other,
              detail: L("Burrito Software's apps."),
              category: L("Community")),
        .init(name: "Cizzuk Source", url: "https://i.cizzuk.net/altstore/source.pal.json", kind: .altSource, store: .other,
              detail: L("Cizzuk's apps."),
              category: L("Community")),
        .init(name: "stux", url: "https://alt.stux.me/repo.json", kind: .altSource, store: .other,
              detail: L("stux's apps."),
              category: L("Community")),
        .init(name: "crystall1ne", url: "https://alt.crystall1ne.dev", kind: .altSource, store: .other,
              detail: L("crystall1ne's curated apps."),
              category: L("Community")),
        .init(name: "SalupovTeam", url: "https://adp.salupovteam.com/altrepo.json", kind: .altSource, store: .other,
              detail: L("The Salupov team's apps."),
              category: L("Community")),
        .init(name: "Spicy Sparks", url: "https://esound.app/downloads/source.json", kind: .altSource, store: .other,
              detail: L("Spicy Sparks' apps."),
              category: L("Community")),
        .init(name: "ULTRAHORSE Market", url: "https://cdn.squadblast.com/market/marketplace.json", kind: .altSource, store: .other,
              detail: L("ULTRAHORSE's own marketplace."),
              category: L("Community")),

        // GitHub release feeds: one app per .ipa on the latest releases.
        .init(name: "SideStore", url: "https://github.com/SideStore/SideStore", kind: .github, store: .sideStore,
              detail: L("SideStore's releases, read straight from GitHub."),
              category: L("GitHub releases")),
        .init(name: "LiveContainer", url: "https://github.com/LiveContainer/LiveContainer", kind: .github, store: .other,
              detail: L("Run apps inside LiveContainer without a reboot."),
              category: L("GitHub releases")),
        .init(name: "UTM (GitHub)", url: "https://github.com/utmapp/UTM", kind: .github, store: .other,
              detail: L("UTM's GitHub releases, including the JIT build."),
              category: L("GitHub releases")),
        .init(name: "PPSSPP", url: "https://github.com/hrydgard/ppsspp", kind: .github, store: .other,
              detail: L("The PSP emulator, whose official iOS build lives on GitHub."),
              category: L("GitHub releases")),
        .init(name: "Provenance (GitHub)", url: "https://github.com/Provenance-Emu/Provenance", kind: .github, store: .other,
              detail: L("Multi-system emulator for iOS, tvOS and macOS."),
              category: L("GitHub releases")),
        .init(name: "Delta", url: "https://github.com/rileytestut/Delta", kind: .github, store: .other,
              detail: L("Delta's source releases, if you'd rather not use AltStore."),
              category: L("GitHub releases")),
    ] }
}

/// The repository market: popular sources to add in one tap.
///
/// A curated list rather than a search: the point is to give a new install
/// something to browse without knowing any links, and to be honest about what
/// each one carries.
struct RepositoryMarketView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var store: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var adding: Set<String> = []
    @State private var note: String?

    private var visible: [RepositoryDirectory.Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return RepositoryDirectory.all }
        return RepositoryDirectory.all.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.detail.localizedCaseInsensitiveContains(trimmed)
                || $0.category.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var sections: [(title: String, entries: [RepositoryDirectory.Entry])] {
        var order: [String] = []
        var grouped: [String: [RepositoryDirectory.Entry]] = [:]
        for entry in visible {
            if grouped[entry.category] == nil { order.append(entry.category) }
            grouped[entry.category, default: []].append(entry)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text(L("Popular repositories, ready to add. Everything here can be browsed in the marketplace and installed the same way as any other app."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.headline)
                            ForEach(section.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("Repositories"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text(L("Search repositories")))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
    }

    private func row(_ entry: RepositoryDirectory.Entry) -> some View {
        let added = store.sources.contains { $0.url.absoluteString == entry.url }
        let busy = adding.contains(entry.id)
        return PanelCard {
            HStack(alignment: .top, spacing: 12) {
                SourceIcon(url: entry.icon, side: 40, fallback: "shippingbox.fill", corner: 9)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(entry.kind == .github ? "GitHub" : entry.store.title)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent2.opacity(0.16)))
                            .foregroundStyle(Theme.accent2)
                    }
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if busy {
                    ProgressView().controlSize(.small)
                } else if added {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                } else {
                    Button(L("Add")) {
                        add(entry)
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func add(_ entry: RepositoryDirectory.Entry) {
        adding.insert(entry.id)
        note = nil
        Task {
            let message = await store.add(entry.url)
            adding.remove(entry.id)
            if let message { note = "\(entry.name): \(message)" }
        }
    }
}
