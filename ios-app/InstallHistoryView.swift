import SwiftUI
import UIKit

/// What has been installed, newest first, and the way back to an earlier build.
///
/// The row a rollback needs is here for every app whose cached copy is still on
/// disk: installing it again signs it fresh and replaces the app in place, so the
/// app's data survives.
struct InstallHistoryView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var engine: Engine
    @ObservedObject private var history = InstallHistory.shared

    @State private var pendingClear = false
    /// Which entries still have their copy, checked once per appearance instead
    /// of once per row per body — with 200 rows that was 200 file checks a
    /// redraw.
    @State private var onDisk: Set<UUID> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                BrandHeader(icon: "clock.arrow.circlepath", title: L("Install history")) {
                    if !history.entries.isEmpty {
                        StatusPill(text: L("%ld build(s)", history.entries.count),
                                   systemImage: "shippingbox", color: Theme.accent2)
                    }
                }
                .cascadeItem(0)

                if history.entries.isEmpty {
                    PanelCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Nothing installed yet"))
                                .font(.headline)
                            Text(L("Every install is recorded here with the copy SideInstaller kept, so an earlier build is one tap away."))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .cascadeItem(1)
                } else {
                    ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry).cascadeItem(min(index + 1, 8))
                    }
                    Button(role: .destructive) {
                        pendingClear = true
                    } label: {
                        Text(L("Clear the history"))
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .cascadeItem(9)
                }
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
        .confirmationDialog(L("Clear the install history?"),
                            isPresented: $pendingClear) {
            Button(L("Clear"), role: .destructive) {
                history.clear()
                Haptics.destructive()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("The history and its rollback copies are removed. The latest re-signing cache stays on disk."))
        }
        .onAppear(perform: checkDisk)
        .onChange(of: history.entries.count) { _, _ in checkDisk() }
    }

    /// Existence checks are file-system work: done once, off the main actor,
    /// for the whole list.
    @MainActor
    private func checkDisk() {
        let entries = history.entries
        Task {
            let present = await Task.detached(priority: .utility) { () -> Set<UUID> in
                var found = Set<UUID>()
                for entry in entries where entry.cachedURL != nil { found.insert(entry.id) }
                return found
            }.value
            onDisk = present
        }
    }

    private func row(_ entry: InstallHistory.Entry) -> some View {
        let isOnDisk = onDisk.contains(entry.id)
        return PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isOnDisk ? "shippingbox.fill" : "clock")
                        .font(.title3)
                        .foregroundStyle(isOnDisk ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if let version = entry.version {
                                Text(version)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(.white.opacity(0.08)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(entry.bundleID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text([entry.date.formatted(date: .abbreviated, time: .shortened), entry.origin]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                if isOnDisk {
                    Button {
                        Haptics.tap()
                        if let url = entry.cachedURL { engine.installLocalIPA(at: url) }
                    } label: {
                        Label(L("Install this build again"), systemImage: "arrow.uturn.backward")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.isRunning)
                } else {
                    Text(L("Its copy is no longer on disk."))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

