import SwiftUI
import UIKit

/// What's been injected into the apps SideInstaller installed, and how to take it
/// back out.
///
/// Read from the stored `.ipa` rather than from the device: the binary inside the
/// cached build is the one that was signed, and its load commands list every
/// library the app pulls in. Anything that isn't Apple's is a tweak, a framework
/// or an injector.
struct TweakManagerView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var engine: Engine

    /// One stored build and the libraries it loads.
    struct Stored: Identifiable {
        let build: IPACache.Cached
        let libraries: [String]
        let injected: Bool
        /// False when the executable couldn't be read, which is not the same as
        /// an executable that links nothing.
        var readable = true

        var id: String { build.bundleID }
        /// The names that could be removed: `.dylib` leaves only.
        var removable: [String] { libraries.filter { $0.lowercased().hasSuffix(".dylib") } }
    }

    @State private var items: [Stored] = []
    @State private var isReading = false
    @State private var pendingStrip: Stored?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                header.cascadeItem(0)
                if isReading {
                    ProgressView().padding(.top, 20)
                } else if items.isEmpty {
                    emptyCard.cascadeItem(1)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        card(item).cascadeItem(min(index + 1, 6))
                    }
                }
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
        .task { await load() }
        .confirmationDialog(L("Reinstall without these libraries?"),
                            isPresented: Binding(get: { pendingStrip != nil },
                                                 set: { if !$0 { pendingStrip = nil } }),
                            presenting: pendingStrip) { item in
            Button(L("Remove them and reinstall"), role: .destructive) {
                strip(item)
                pendingStrip = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingStrip = nil }
        } message: { item in
            Text(L("%@ keeps its data: the build is signed again without the libraries, and installed over itself.", item.build.displayName))
        }
    }

    private var header: some View {
        BrandHeader(icon: "syringe", title: L("Injected libraries")) {
            if !items.isEmpty {
                StatusPill(text: L("%ld build(s)", items.count),
                           systemImage: "shippingbox", color: Theme.accent2)
            }
        }
    }

    private var emptyCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Nothing to inspect yet"))
                    .font(.headline)
                Text(L("This reads the builds SideInstaller keeps — install something, then its libraries appear here. A tweak shows up as a .dylib the app loads which isn't Apple's."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card(_ item: Stored) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.injected ? "syringe.fill" : "app.badge.checkmark")
                        .font(.title3)
                        .foregroundStyle(item.injected ? Theme.accent2 : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.build.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(item.build.bundleID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                if !item.readable {
                    Text(L("The executable couldn't be read, so its libraries are unknown."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if item.libraries.isEmpty {
                    Text(L("Links nothing but Apple's frameworks."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(item.libraries, id: \.self) { library in
                        HStack(spacing: 6) {
                            Image(systemName: library.lowercased().hasSuffix(".dylib")
                                  ? "puzzlepiece.extension" : "shippingbox")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(library)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                }
                if !item.removable.isEmpty {
                    Button {
                        pendingStrip = item
                    } label: {
                        Label(L("Remove and reinstall"), systemImage: "scissors")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.isRunning)
                }
            }
        }
    }

    private func load() async {
        guard items.isEmpty else { return }
        isReading = true
        let read = await Task.detached(priority: .userInitiated) { () -> [Stored] in
            // The folder listing belongs here too: this runs off the main actor.
            let builds = IPACache.all()
            return builds.compactMap { build -> Stored? in
                guard let archive = IPALibrary.archiveFiles(at: build.url),
                      let app = archive.first(where: {
                          $0.path.hasSuffix("/Info.plist") && $0.path.contains("Payload/")
                      }) else { return nil }
                let bundle = String(app.path.dropLast("/Info.plist".count))
                let plist = IPALibrary.contents(of: app, in: build.url)
                    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
                    as? [String: Any]
                let executable = (plist?["CFBundleExecutable"] as? String)
                    ?? (bundle as NSString).lastPathComponent
                // Split in two: as one guard the type checker gives up on the
                // concatenation, the predicate and the call together.
                let binaryPath = bundle + "/" + executable
                guard let file = archive.first(where: { $0.path == binaryPath }) else { return nil }
                // The load commands are at the head of the binary: a bounded
                // read is all this needs, and a 90 MB executable stops being a
                // 90 MB allocation per build.
                guard let head = IPALibrary.prefix(of: file, in: build.url, limit: 8 << 20)
                else { return Stored(build: build, libraries: [], injected: false, readable: false) }
                let libraries = MachOInject.tweakLibraries(in: head)
                return Stored(build: build, libraries: libraries, injected: !libraries.isEmpty)
            }
        }.value
        items = read
        isReading = false
    }

    /// Copies the cached build, removes the libraries from its main binary,
    /// repacks it, and installs that.
    private func strip(_ item: Stored) {
        Haptics.destructive()
        Task {
            let target = item.removable
            guard !target.isEmpty else { return }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("stripped-\(UUID().uuidString).ipa")
            do {
                try await Task.detached(priority: .userInitiated) {
                    try IPAPatch.strip(item.build.url, libraries: Set(target), writing: temp)
                }.value
                engine.log("Stripped \(target.count) library(ies) from \(item.build.displayName).")
                engine.installLocalIPA(at: temp)
            } catch {
                engine.log("⚠️ Couldn't strip \(item.build.displayName): \(error.localizedDescription)")
            }
        }
    }
}
