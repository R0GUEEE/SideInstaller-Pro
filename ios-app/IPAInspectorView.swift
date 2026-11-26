import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Reads an `.ipa` and says what installing it will do before anything is
/// downloaded, signed or registered: its identity, what iOS and hardware it
/// needs, whether its code is encrypted, what profiles and extensions it
/// carries, and every reason it might not work.
///
/// Pushed from Tools (relies on its `NavigationStack`).
struct IPAInspectorView: View {
    /// Observed so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var engine: Engine

    @State private var report: IPAReport?
    @State private var isReading = false
    @State private var failure: String?
    @State private var showImporter = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header.cascadeItem(0)
                if let report {
                    identityCard(report).cascadeItem(1)
                    compatibilityCard(report).cascadeItem(2)
                    signingCard(report).cascadeItem(3)
                    issuesCard(report).cascadeItem(4)
                    actionCard(report).cascadeItem(5)
                } else {
                    introCard.cascadeItem(1)
                }
            }
            .padding(20)
            .pageColumn()
            .animation(.smooth(duration: 0.35), value: report?.url)
        }
        .background(AppBackground())
        .sheet(isPresented: $showImporter) {
            FileImporterRepresentableView(allowedContentTypes: [.ipa]) { urls in
                guard let url = urls.first else { return }   // empty means cancelled
                read(url)
            }
            .ignoresSafeArea()
        }
        // Whatever build the Install tab is set to is the obvious thing to
        // open this page with.
        .onAppear {
            guard report == nil, !isReading,
                  let current = IPALibrary.customImport()?.url else { return }
            read(current)
        }
    }

    // MARK: Header

    private var header: some View {
        BrandHeader(icon: "doc.text.magnifyingglass", title: L("Inspect .ipa")) {
            EmptyView()
        }
    }

    // MARK: Nothing read yet

    private var introCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Check a build before you sign it"))
                    .font(.headline)
                Text(L("SideInstaller reads the archive where it lies — no unpacking, no download — and reports what the app declares about itself. It also flags the things that quietly break a sideloaded app: a build that needs a newer iOS, code that's still encrypted from the App Store, or an extension with no profile of its own."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if isReading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L("Reading the archive…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let failure {
                    Text(failure)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                Button {
                    showImporter = true
                } label: {
                    Label(L("Choose .ipa"), systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isReading)
            }
        }
    }

    // MARK: Identity

    private func identityCard(_ report: IPAReport) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    iconView(report)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Text(L("Version %@ (%@)",
                               report.version ?? L("unknown"), report.build ?? L("none")))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 10) {
                    InspectRow(label: L("Bundle ID"),
                               value: report.bundleID.isEmpty ? L("missing") : report.bundleID,
                               mono: true, warn: report.bundleID.isEmpty)
                    InspectRow(label: L("Download"), value: report.sizeText)
                    InspectRow(label: L("Unpacked"),
                               value: L("%@ in %ld files", report.unpackedText, report.fileCount))
                    if let hash = report.sha256 {
                        InspectRow(label: L("SHA-256"), value: hash, mono: true, wraps: true)
                    } else if isReading {
                        InspectRow(label: L("SHA-256"), value: L("hashing…"))
                    }
                }
                Text(report.fileName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func iconView(_ report: IPAReport) -> some View {
        let side: CGFloat = 58
        if let data = report.icon, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.brand)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: side, height: side)
        }
    }

    // MARK: Compatibility

    private func compatibilityCard(_ report: IPAReport) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle(L("Compatibility"), systemImage: "iphone.gen3")
                VStack(alignment: .leading, spacing: 10) {
                    InspectRow(label: L("Minimum iOS"),
                               value: report.minimumOS ?? L("not stated"),
                               warn: needsNewerOS(report))
                    if let built = report.executableMinimumOS, built != report.minimumOS {
                        InspectRow(label: L("Built for iOS"), value: built)
                    }
                    InspectRow(label: L("Platforms"),
                               value: report.platforms.isEmpty ? L("not stated")
                                                                : report.platforms.joined(separator: ", "))
                    InspectRow(label: L("Devices"),
                               value: report.deviceFamilies.isEmpty ? L("not stated")
                                                                    : report.deviceFamilies.joined(separator: ", "))
                    InspectRow(label: L("Architectures"),
                               value: report.architectures.isEmpty ? L("no executable")
                                                                   : report.architectures.joined(separator: ", "),
                               warn: !report.architectures.isEmpty
                                   && !report.architectures.contains { $0.hasPrefix("arm64") })
                    if report.isEncrypted {
                        InspectRow(label: L("Code"), value: L("encrypted (App Store)"), warn: true)
                    }
                }
                Text(L("This iPhone runs iOS %@.", ProcessInfo.processInfo.operatingSystemVersionString))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func needsNewerOS(_ report: IPAReport) -> Bool {
        guard let needed = report.minimumOS?.split(separator: ".").first,
              let major = Int(needed) else { return false }
        return major > ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    // MARK: Signing

    private func signingCard(_ report: IPAReport) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle(L("Signing"), systemImage: "signature")
                if let profile = report.profile {
                    VStack(alignment: .leading, spacing: 10) {
                        InspectRow(label: L("Embedded profile"),
                                   value: profile.teamName.isEmpty ? L("unnamed team") : profile.teamName)
                        InspectRow(label: L("App ID"), value: profile.applicationIdentifier,
                                   mono: true, wraps: true)
                        InspectRow(label: L("Expires"),
                                   value: expiryText(profile),
                                   warn: profile.isExpired)
                    }
                    Text(L("Signing replaces this profile with one for your Apple ID, so its expiry doesn't apply to the app you install."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(L("No embedded profile. SideInstaller issues one for your Apple ID when it signs this build."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !report.extensions.isEmpty {
                    Divider().opacity(0.2)
                    Text(L("Extensions"))
                        .font(.subheadline.weight(.semibold))
                    ForEach(report.extensions) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.footnote)
                                .foregroundStyle(Theme.accent2)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.subheadline.weight(.medium))
                                Text(item.bundleID ?? item.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: item.hasProfile ? "checkmark.seal" : "seal")
                                .font(.footnote)
                                .foregroundStyle(item.hasProfile ? .green : .secondary)
                        }
                    }
                }
            }
        }
    }

    private func expiryText(_ profile: ProvisioningProfile) -> String {
        guard let date = profile.expirationDate else { return L("unknown") }
        let days = profile.daysRemaining ?? 0
        if profile.isExpired { return L("expired %@", date.formatted(date: .abbreviated, time: .omitted)) }
        return L("%@ (in %ld days)", date.formatted(date: .abbreviated, time: .omitted), days)
    }

    // MARK: Issues

    @ViewBuilder
    private func issuesCard(_ report: IPAReport) -> some View {
        if !report.issues.isEmpty {
            PanelCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle(L("Before you install"), systemImage: "exclamationmark.triangle")
                    ForEach(report.issues) { issue in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: symbol(for: issue.severity))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(color(for: issue.severity))
                                .frame(width: 22)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(issue.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(issue.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func symbol(for severity: IPAReport.Issue.Severity) -> String {
        switch severity {
        case .blocker: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .note:    return "info.circle.fill"
        }
    }

    private func color(for severity: IPAReport.Issue.Severity) -> Color {
        switch severity {
        case .blocker: return .red
        case .warning: return .orange
        case .note:    return .secondary
        }
    }

    // MARK: Actions

    private func actionCard(_ report: IPAReport) -> some View {
        PanelCard {
            VStack(spacing: 12) {
                Button {
                    // Copies it into the custom slot first: the run reads that.
                    engine.installLocalIPA(at: report.url)
                } label: {
                    Label(L("Install this .ipa"), systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!report.installable || engine.isRunning || engine.isImportingIPA)

                Button {
                    showImporter = true
                } label: {
                    Label(L("Inspect another"), systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if !report.installable {
                    Text(L("The problems marked in red stop this build from working. It won't be installed."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if engine.isRunning {
                    Text(L("An install is already running. Open the Install tab to follow it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Reads a picked file off the main actor: a large IPA takes a moment.
    private func read(_ url: URL) {
        guard !isReading else { return }
        isReading = true
        failure = nil
        report = nil
        Task {
            let read = await Task.detached(priority: .userInitiated) {
                IPAInspector.inspect(url)
            }.value
            isReading = false
            guard let read else {
                failure = L("%@ couldn't be read as an IPA. It may be an error page saved as a file, or a download that stopped partway.",
                            url.lastPathComponent)
                return
            }
            report = read
        }
    }
}

/// One label and its value, with the value free to wrap when it's long (a
/// SHA-256, an App ID).
private struct InspectRow: View {
    var label: String
    var value: String
    var mono = false
    var wraps = false
    var warn = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .font(mono ? .footnote.monospaced() : .subheadline)
                .foregroundStyle(AnyShapeStyle(warn ? Color.orange : Color.primary))
                .multilineTextAlignment(.leading)
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
