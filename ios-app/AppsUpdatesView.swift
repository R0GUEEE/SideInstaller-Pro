import SwiftUI

/// One app with a newer release in the configured sources.
struct AppUpdate: Identifiable {
    let status: SideloadedAppStatus
    let version: String
    let url: URL

    var id: String { status.app.bundleID }
}

/// Everything waiting for an update, as a sheet opened from the My Apps toolbar
/// — the icon with the count is the entry point now, rather than a card at the
/// top of the page.
struct UpdatesSheet: View {
    @ObservedObject var manager: SideloadedAppsManager
    let updates: [AppUpdate]
    /// Installs one, or the whole list, in the order given.
    let install: ([AppUpdate]) -> Void

    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if updates.isEmpty {
                        PanelCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("Everything is up to date"))
                                    .font(.headline)
                                Text(L("An app appears here when a source you follow carries a release newer than the version on this iPhone."))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        ForEach(Array(updates.enumerated()), id: \.element.id) { index, update in
                            row(update).cascadeItem(min(index, 6))
                        }
                        Text(L("Each update is the source's newest release, downloaded and signed with your Apple ID. Installing one replaces the app and keeps its data."))
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
            .navigationTitle(L("Updates"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !updates.isEmpty {
                    VStack(spacing: 6) {
                        Button {
                            working = true
                            install(updates)
                            dismiss()
                        } label: {
                            Label(updates.count == 1
                                  ? L("Install the update")
                                  : L("Install all %d updates", updates.count),
                                  systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(working || engine.isRunning || manager.isRefreshing)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .background(.ultraThinMaterial)
                }
            }
        }
    }

    private func row(_ update: AppUpdate) -> some View {
        PanelCard {
            HStack(alignment: .center, spacing: 12) {
                icon(update)
                VStack(alignment: .leading, spacing: 3) {
                    Text(update.status.app.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(update.status.app.version ?? "—")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(update.version)
                            .foregroundStyle(Theme.accent2)
                    }
                    .font(.caption.monospaced())
                }
                Spacer(minLength: 8)
                Button {
                    install([update])
                    dismiss()
                } label: {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(working || engine.isRunning || manager.isRefreshing)
                .accessibilityLabel(L("Install the update for %@", update.status.app.name))
            }
        }
    }

    private func icon(_ update: AppUpdate) -> some View {
        ZStack {
            if let image = manager.icon(for: update.status.app.bundleID) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.brand)
                Text(String(update.status.app.name.prefix(1)).uppercased())
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
