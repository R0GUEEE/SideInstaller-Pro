import SwiftUI

@MainActor
struct AppFilesView: View {
    @ObservedObject private var engine = Engine.shared
    @State private var apps: [DeviceConnection.InstalledApp] = []
    @State private var selected: DeviceConnection.InstalledApp?
    @State private var fullAccess = false
    @State private var path = "/"
    @State private var entries: [AppFileEntry] = []
    @State private var search = ""
    @State private var busy = false
    @State private var error: String?
    @State private var pending: Removal?
    @State private var showRemoval = false

    private struct Removal {
        let path: String
        let contentsOnly: Bool
    }
    private var root: String { fullAccess ? "/" : "/Documents" }
    private var filteredApps: [DeviceConnection.InstalledApp] {
        apps.filter { search.isEmpty || ($0.displayName ?? "").localizedCaseInsensitiveContains(search)
            || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }
    private var listedBytes: Int64 {
        entries.filter { !$0.isDirectory && !$0.isLink }.reduce(0) { sum, entry in
            let (value, overflow) = sum.addingReportingOverflow(entry.size)
            return overflow ? Int64.max : value
        }
    }

    var body: some View {
        List {
            Section {
                Text("Browse storage exposed by iOS through your paired device connection. Full containers require development signing; other apps may expose only shared Documents or deny access.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if busy { ProgressView("Working…") }
            if let error {
                Section("Could not complete operation") {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Text("Unlock the device and check pairing and LocalDevVPN. Close the target app before deleting files. If cleanup failed, some files may already have been removed.")
                        .font(.footnote)
                }
            }
            if let selected {
                Section {
                    Text(selected.displayName ?? selected.bundleID).font(.headline)
                    Text(selected.bundleID).font(.caption).textSelection(.enabled)
                    Label(fullAccess ? "Full container" : "Shared Documents only",
                          systemImage: fullAccess ? "folder" : "lock.doc")
                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    Text("\(entries.count) items • \(ByteCountFormatter.string(fromByteCount: listedBytes, countStyle: .file)) in files here (excludes subfolders)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Choose another app") {
                        self.selected = nil
                        entries = []
                        error = nil
                    }
                    if path != root {
                        Button("Up one folder", systemImage: "arrow.up") {
                            let parent = (path as NSString).deletingLastPathComponent
                            run { try await loadFolder(parent) }
                        }
                    }
                }
                Section("Files") {
                    if entries.isEmpty && !busy { Text("No files loaded").foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        HStack {
                            if entry.isDirectory {
                                Button { run { try await loadFolder(entry.path) } } label: {
                                    Label(entry.name, systemImage: "folder.fill")
                                }
                            } else {
                                Label(entry.name, systemImage: entry.isLink ? "link" : "doc")
                            }
                            Spacer()
                            if !entry.isDirectory {
                                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if AppFilePath.deletable(entry.path, root: root) {
                                Button(role: .destructive) { confirm(entry.path, contentsOnly: false) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete \(entry.name)")
                            }
                        }
                    }
                }
                Section {
                    if fullAccess {
                        Button("Clear cache contents", role: .destructive) { confirm("/Library/Caches", contentsOnly: true) }
                        Button("Clear temporary files", role: .destructive) { confirm("/tmp", contentsOnly: true) }
                    }
                    Button("Clear Documents contents", role: .destructive) { confirm("/Documents", contentsOnly: true) }
                } header: {
                    Text("Clear storage")
                } footer: {
                    Text("Documents can contain irreplaceable files and saved app data. Deletion cannot be undone. This does not reset keychain data, shared app groups, or storage iOS does not expose. SideInstaller's automatic cleanup never deletes another app's data.")
                }
            } else {
                Section("Installed apps") {
                    TextField("Search apps", text: $search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    ForEach(filteredApps, id: \.bundleID) { app in
                        Button {
                            run {
                                let full = try await engine.onDeviceQueue { try engine.connection.appFileAccess(app.bundleID) }
                                fullAccess = full
                                selected = app
                                path = full ? "/" : "/Documents"
                                entries = []
                                try await loadFolder(path)
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(app.displayName ?? app.bundleID)
                                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .disabled(busy || engine.isRunning)
        .navigationTitle("App files & storage")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { reload() }
                    .disabled(busy || engine.isRunning)
            }
        }
        .overlay {
            if engine.isRunning { Text("Wait for installation to finish.").padding().background(.regularMaterial) }
        }
        .confirmationDialog("Permanently delete app data?", isPresented: $showRemoval, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                guard let pending, let selected else { return }
                let full = fullAccess
                run {
                    do {
                        try await engine.onDeviceQueue {
                            try engine.connection.deleteAppFiles(selected.bundleID, full: full,
                                                                 path: pending.path, contentsOnly: pending.contentsOnly)
                        }
                    } catch {
                        entries = []
                        throw error
                    }
                    try await loadFolder(path)
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("\(selected?.displayName ?? selected?.bundleID ?? "App"): \(pending?.path ?? "")\n\(pending?.contentsOnly == true ? "All contents will be removed." : "This item and any files inside will be removed.") Close the app first. Back up anything you need; this cannot be undone.")
        }
        .task { if apps.isEmpty { reload() } }
    }

    private func confirm(_ path: String, contentsOnly: Bool) {
        pending = Removal(path: path, contentsOnly: contentsOnly)
        showRemoval = true
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !engine.isRunning else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await engine.prepareDeviceLink()
                try await operation()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func reload() {
        run {
            if selected != nil {
                try await loadFolder(path)
            } else {
                apps = try await engine.onDeviceQueue { try engine.connection.installedApps() }
                    .filter { $0.bundleID != Bundle.main.bundleIdentifier }
                    .sorted { ($0.displayName ?? $0.bundleID).localizedStandardCompare($1.displayName ?? $1.bundleID) == .orderedAscending }
            }
        }
    }

    private func loadFolder(_ newPath: String) async throws {
        guard let selected else { return }
        let full = fullAccess
        let loaded = try await engine.onDeviceQueue {
            try engine.connection.appFiles(selected.bundleID, full: full, path: newPath)
        }
        path = newPath
        entries = loaded
    }
}
