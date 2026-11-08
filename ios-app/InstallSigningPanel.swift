import SwiftUI
import UniformTypeIdentifiers

/// The expandable signing configuration under the install menu: identity,
/// plist and entitlement editing, capabilities, the libraries a build loads, and
/// the tweaks patched into it with the injectors they need.
struct InstallSigningPanel: View {

    /// Which half of the configuration this instance draws. The two are shown
    /// as separate collapsible sections on the Install tab.
    enum Part {
        case ipa
        case tweaks
    }

    var part: Part = .ipa

    @ObservedObject private var config = AppConfigStore.shared
    @ObservedObject private var library = TweakLibrary.shared
    @EnvironmentObject private var loc: Localizer
    /// The last import's detection scan.
    @EnvironmentObject private var engine: Engine

    @State private var showAppConfig = false
    @State private var showBrowser = false
    @State private var showLibrary = false
    /// What the in-app-purchase switch last did.
    @State private var iapNote: String?
    /// The pairing-file sheet.
    @State private var showPairing = false

    var body: some View {
        Group {
            switch part {
            case .ipa:    ipaPart
            case .tweaks: tweakPart
            }
        }
        .sheet(isPresented: $showAppConfig) { AppConfigView() }
        .sheet(isPresented: $showBrowser) { TweakBrowserView(store: config) }
        .sheet(isPresented: $showLibrary) { TweakLibraryView() }
        .sheet(isPresented: $showPairing) { PairingOptionsSheet(engine: engine) }
    }

    /// Everything about the bundle being signed: what it's called, what it
    /// declares, what iOS grants it, and how this iPhone pairs.
    private var ipaPart: some View {
        VStack(alignment: .leading, spacing: 18) {
            identity
            extensions
            plistRows
            capabilities
            detection
            if engine.canSelfPair { pairingRow }
        }
    }

    /// Everything loaded beside the executable.
    private var tweakPart: some View {
        VStack(alignment: .leading, spacing: 18) {
            libraries
            tweaks
        }
    }

    /// The optional pairing file, as a row rather than a chip: it belongs with
    /// the other decisions about how this build is signed and installed.
    private var pairingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Pairing"), systemImage: "lock.doc.fill")
            Button { showPairing = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: engine.importedPairingName == nil
                          ? "lock.iphone" : "checkmark.seal.fill")
                        .foregroundStyle(engine.importedPairingName == nil
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(engine.importedPairingName == nil ? L("Automatic") : L("Imported file"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(engine.importedPairingName ?? L("SideInstaller pairs this iPhone itself."))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .fieldBackground()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Identity"), systemImage: "person.text.rectangle")
            field(L("App name"), prompt: engine.buildIdentity?.name, text: Binding(
                get: { config.config.displayName },
                set: { config.config.displayName = $0 }))
            field(L("Bundle ID"), prompt: engine.buildIdentity?.bundleID, text: Binding(
                get: { config.config.bundleIdentifier },
                set: { config.config.bundleIdentifier = $0 }), mono: true)
            Text(L("A field left empty keeps the build's own value, shown greyed. Nothing is written into the configuration until you type: an untouched import reaches the signer exactly as it was published."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ title: String, prompt: String? = nil,
                       text: Binding<String>, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(title, text: text,
                      prompt: Text((prompt?.isEmpty == false ? prompt! : L("the build's own"))))
                .font(mono ? .caption.monospaced() : .subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldBackground()
        }
    }

    // MARK: Extensions

    /// What plugins this build ships. They are signed with the app, and iOS
    /// requires each one's identifier to sit under the app's — the menu says so
    /// here, before a run, instead of leaving it to a signer failure.
    private var extensions: some View {
        let items = engine.buildExtensions
        return VStack(alignment: .leading, spacing: 8) {
            group(L("Extensions"), systemImage: "puzzlepiece.extension")
            if items.isEmpty {
                Text(L("This build has no app extensions."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.isChild
                              ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(item.isChild ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.path)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text(item.bundleID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.vertical, 1)
                }
                Text(items.contains(where: { !$0.isChild })
                     ? L("An extension whose identifier is outside the app's cannot be signed under it. Rename the app (Identity) so the extension is re-prefixed, or remove the extension.")
                     : L("Each extension is signed with the app and loads the tweaks below it in the same order."))
                    .font(.caption2)
                    .foregroundStyle(items.contains { !$0.isChild } ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Info.plist and entitlements

    private var plistRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Info.plist and entitlements"), systemImage: "list.bullet.rectangle")
            summaryRow(icon: "doc.text",
                       title: L("Info.plist"),
                       detail: config.config.plistEdits.isEmpty
                             ? L("No keys added")
                             : L("%d key(s) added", config.config.plistEdits.count))
            summaryRow(icon: "checkmark.seal",
                       title: L("Entitlements"),
                       detail: config.config.entitlements.isEmpty
                             ? L("None declared")
                             : L("%d entitlement(s)", config.config.entitlements.count))
            Button { showAppConfig = true } label: {
                Label(L("Edit keys and entitlements"), systemImage: "slider.horizontal.3")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func summaryRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Theme.accent2)
                .frame(width: 18)
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer(minLength: 6)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: Capabilities

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Capabilities"), systemImage: "switch.2")
            ForEach(AppCapability.allCases) { capability in
                Toggle(isOn: Binding(get: { config.isEnabled(capability) },
                                     set: { config.set($0, for: capability) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(capability.title)
                            .font(.caption.weight(.semibold))
                        Text(capability.detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            Text(L("A capability writes the plist key the app expects. The matching entitlement is granted only if it is on the App ID: turn it on under Settings › Entitlements, or sign again with Increased Memory Limit, and the profile Apple issues carries it. An entitlement written here alone is recorded in the archive and changes no signature."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Sideload detection

    /// On by default when the build looks like it checks, off when it doesn't.
    /// The scan happens at import, so this is a decision with evidence in front
    /// of it rather than a guess.
    private var detection: some View {
        let report = engine.sideloadFindings
        let on = config.config.bypassesSideloadDetection
        return VStack(alignment: .leading, spacing: 8) {
            group(L("Sideload detection"), systemImage: "shield.lefthalf.filled")
            Toggle(isOn: Binding(get: { on },
                                 set: { config.config.detectionBypass = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Bypass detection"))
                        .font(.caption.weight(.semibold))
                    Text(report == nil
                         ? L("Pick an .ipa and it's scanned for Cydia, Frida, profile and entitlement checks.")
                         : (report?.hasPatchable == true
                            ? L("Found %@ — blanked in the executable.", (report?.markers ?? []).joined(separator: ", "))
                            : L("Nothing recognisable found in this build.")))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if on {
                Text(L("Writes get-task-allow off and empties the detection paths and schemes it can see in the executable. A check that runs on a server, or reads the signature's team ID, still refuses — nothing on this side of the network can change that."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let frameworks = report?.frameworks, !frameworks.isEmpty {
                Text(L("%@ attests to a server — the bypass won't help there.", frameworks.joined(separator: ", ")))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Frameworks and libraries

    private var libraries: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Frameworks and dylibs"), systemImage: "shippingbox")
            Text(config.config.tweaks.isEmpty
                 ? L("Nothing injected yet.")
                 : L("%d library package(s) injected.", config.config.tweaks.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { showLibrary = true } label: {
                    Label(L("Tweak storage"), systemImage: "tray.full")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button { showBrowser = true } label: {
                    Label(L("Browse"), systemImage: "magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if library.items.count > 0 {
                Text(L("%d tweak(s) kept in storage, ready to add.", library.items.count))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Tweaks

    private var tweaks: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Tweaks"), systemImage: "syringe")
            injectionChoices
            purchaseSwitch
            if config.config.tweaks.isEmpty {
                Text(L("A .dylib or .deb added here is unpacked into the app's Frameworks folder and loaded by its main executable."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(config.config.tweaks) { tweak in
                HStack(spacing: 8) {
                    Image(systemName: tweak.isDeb ? "shippingbox.fill" : "doc.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tweak.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if let version = tweak.versionText {
                                Text(version)
                            }
                            if let host = tweak.repositoryHost {
                                Text("·")
                                Text(host)
                            }
                            if let kind = tweak.requiresInjector {
                                Text("·")
                                Text(config.injector(for: kind) == nil
                                     ? L("needs %@", kind.title)
                                     : L("uses %@", kind.title))
                                    .foregroundStyle(config.injector(for: kind) == nil ? .orange : .secondary)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button(role: .destructive) {
                        config.removeTweak(tweak.id)
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// How a library is named and where it goes: the pair the injector uses for
    /// every tweak added from here on, and rewrites for the ones already added.
    private var injectionChoices: some View {
        HStack(spacing: 8) {
            injectionMenu(title: L("Path"),
                          value: config.config.injectionBaseKind.title,
                          options: InjectionBase.allCases.map { base in
                              (base.title, { config.setInjectionBase(base) })
                          })
            injectionMenu(title: L("Folder"),
                          value: config.config.injectionFolderKind.title,
                          options: InjectionFolder.allCases.map { folder in
                              (folder.title, { config.setInjectionFolder(folder) })
                          })
            Spacer(minLength: 0)
        }
    }

    private func injectionMenu(title: String, value: String,
                               options: [(String, () -> Void)]) -> some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.0, action: option.1)
            }
        } label: {
            HStack(spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// The one switch for the three bundled in-app-purchase patches. It adds
    /// all of them because they cover different apps; leaving one out is what
    /// makes a purchase work on one app and fail on the next.
    private var purchaseSwitch: some View {
        let enabled = IAPTweaks.isEnabled(in: config)
        let injector = IAPTweaks.requiredInjector(in: config)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { enabled }, set: { on in
                iapNote = IAPTweaks.setEnabled(on, in: config)
                if on { Haptics.success() } else { Haptics.tap() }
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Free in-app purchases"))
                        .font(.caption.weight(.semibold))
                    Text(L("Satella + iAPCracker + autoRevenuecat, injected together"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if enabled {
                ForEach(IAPTweaks.entries, id: \.fileName) { entry in
                    Text("· " + entry.method)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let injector, config.injector(for: injector) == nil {
                    HStack(spacing: 6) {
                        Text(L("%@ is needed for one of these.", injector.title))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Button(L("Get %@", injector.title)) {
                            Task { await config.downloadInjector(injector) }
                        }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent2)
                    }
                }
            }
            if let iapNote {
                Text(iapNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("A local receipt check is what these answer. An app that validates on its own server, or uses StoreKit 2's signed transactions, may still refuse."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func group(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
