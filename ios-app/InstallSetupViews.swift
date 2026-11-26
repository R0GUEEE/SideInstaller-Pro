import SwiftUI
import UniformTypeIdentifiers

/// The four things SideInstaller can put on this iPhone, as cards instead of a
/// menu: what each one is, in the card, before it's chosen.
struct InstallSourceChooser: View {
    @Binding var source: InstallSource
    var disabled = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(InstallSource.allCases) { option in
                let selected = option == source
                Button {
                    Haptics.tap()
                    source = option
                } label: {
                    card(option, selected: selected)
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    private func card(_ option: InstallSource, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: option))
                    .font(.subheadline)
                    .foregroundStyle(selected ? Theme.accent2 : Color.secondary)
                Spacer(minLength: 2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accent2) : AnyShapeStyle(.tertiary))
            }
            Text(option.shortName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.detail(for: option))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.55) : Color.primary.opacity(0.06),
                              lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private static func symbol(for source: InstallSource) -> String {
        switch source {
        case .sideStore:     return "shippingbox.fill"
        case .liveContainer: return "square.stack.3d.up.fill"
        case .madeira:       return "bolt.horizontal.circle.fill"
        case .custom:        return "doc.badge.plus"
        }
    }

    private static func detail(for source: InstallSource) -> String {
        switch source {
        case .sideStore:     return L("On-device sideloading")
        case .liveContainer: return L("SideStore inside LiveContainer")
        case .madeira:       return L("Sideloading with JIT")
        case .custom:        return L("Your own .ipa")
        }
    }
}

/// One install option, summarised: what it is, what it's set to, and a tap to
/// change it. The chips sit above the Install button so an advanced install is
/// configured before the run starts, not found afterwards.
struct InstallOptionChip: View {
    var icon: String
    var title: String
    var value: String
    var tint: Color = Theme.accent2
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Which release of the chosen build to install, as a list rather than a menu —
/// a long title or a maintainer's warning has room to be read.
struct ReleaseVersionSheet: View {
    @ObservedObject var engine: Engine
    let source: InstallSource

    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    private var catalog: ReleaseCatalog? { engine.releaseCatalogs[source] }
    private var latest: ReleaseVersion? { catalog?.latest[engine.selectedChannel] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PanelCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Text(L("Channel"))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Picker(L("Channel"), selection: $engine.releaseChannel) {
                                    ForEach(ReleaseChannel.allCases) { channel in
                                        Text(channel.displayName).tag(channel)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(maxWidth: 220)
                            }
                            if !source.hasNightly {
                                Text(L("%@ has no nightly build, so it's always installed from the stable channel.", source.shortName))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    PanelCard {
                        VStack(alignment: .leading, spacing: 10) {
                            row(title: latestLabel,
                                detail: latest.flatMap { $0.hasRemark ? $0.menuTitle : nil },
                                selected: engine.selectedVersion == nil) {
                                engine.selectedVersion = nil
                                dismiss()
                            }
                            ForEach(catalog?.others[engine.selectedChannel] ?? []) { version in
                                Divider().opacity(0.15)
                                row(title: version.title,
                                    detail: version.hasRemark ? version.menuTitle : nil,
                                    selected: engine.selectedVersion?.id == version.id) {
                                    engine.selectedVersion = version
                                    dismiss()
                                }
                            }
                            if let error = engine.catalogErrors[source] {
                                Divider().opacity(0.15)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("Couldn't load the other versions: %@", error))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button(L("Try again")) {
                                        Task { await engine.loadReleaseCatalog(for: source, force: true) }
                                    }
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.accent2)
                                    .buttonStyle(.plain)
                                }
                            }
                            if engine.loadingCatalog == source {
                                Divider().opacity(0.15)
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(L("Looking for other versions…"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Text(L("A specific release is downloaded from %@'s GitHub releases; the newest is what a plain Install uses.", source.repo ?? "GitHub"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("%@ version", source.shortName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .task(id: source) { await engine.loadReleaseCatalog(for: source) }
        }
    }

    private var latestLabel: String {
        guard let latest, latest.tag != "nightly" else { return L("Latest") }
        return L("Latest (%@)", latest.title)
    }

    private func row(title: String, detail: String?, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.footnote)
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accent2) : AnyShapeStyle(.tertiary))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, detail != title {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The pairing-file choice, as a page: pair this iPhone automatically, or give
/// SideInstaller a file made somewhere else.
struct PairingOptionsSheet: View {
    @ObservedObject var engine: Engine

    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showImporter = false

    /// SideStore's guide to making a pairing file on a computer.
    private static let docsURL = "https://docs.sidestore.io/docs/advanced/alternative#pairing"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PanelCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(engine.importedPairingName == nil ? L("Automatic") : L("Imported file"))
                                .font(.headline)
                            Text(engine.importedPairingName == nil
                                 ? L("SideInstaller pairs this iPhone itself, over Wi-Fi, when a run starts. Nothing to set up — keep Wi-Fi on for the first install.")
                                 : L("SideInstaller uses %@ instead of pairing this iPhone itself.", engine.importedPairingName ?? ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    PanelCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Button { showImporter = true } label: {
                                HStack(spacing: 8) {
                                    if engine.isImportingPairing {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: engine.importedPairingName == nil
                                              ? "square.and.arrow.down" : "checkmark.circle.fill")
                                            .foregroundStyle(engine.importedPairingName == nil
                                                             ? Color.secondary : Theme.accent2)
                                    }
                                    Text(engine.importedPairingName == nil
                                         ? L("Import a pairing file")
                                         : L("Replace the pairing file"))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .fieldBackground()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(engine.isImportingPairing)

                            if engine.sideStoreInstalled {
                                Button { engine.requestSideStorePairing() } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "arrow.uturn.backward.circle")
                                            .foregroundStyle(.secondary)
                                        Text(L("Get it from SideStore"))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "arrow.up.forward.app")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(Theme.accent2)
                                    }
                                    .fieldBackground()
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Text(L("SideStore opens and sends back the pairing file it has."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Button {
                                if let url = URL(string: Self.docsURL) { openURL(url) }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(L("How do I make one?"))
                                    Image(systemName: "arrow.up.right")
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.accent2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("Pairing file"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showImporter) {
                FileImporterRepresentableView(allowedContentTypes: UTType.pairingFileTypes) { urls in
                    guard let url = urls.first else { return }
                    Task { await engine.importPairingFile(from: url) }
                }
                .ignoresSafeArea()
            }
        }
    }
}
