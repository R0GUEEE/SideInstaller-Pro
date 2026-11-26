import Foundation

/// Looking for, and defeating, the checks an app uses to notice it was
/// sideloaded.
///
/// What this can honestly do is limited to the build itself:
///
/// - **Strings.** Jailbreak and sideload checks are usually a list of paths and
///   schemes — `/Applications/Cydia.app`, `cydia://`, `embedded.mobileprovision`
///   — stored as C strings in the executable. Blanking the first byte of each
///   leaves the file's layout untouched (same length, same offsets) and makes
///   the check compare against an empty string, which no file or URL is.
/// - **Frameworks.** `DeviceCheck` and `AppAttest` mean the app attests its
///   install to a server. Nothing on-device can defeat that; finding them is
///   reported so the limit is visible rather than a silent failure.
/// - **Entitlements.** `get-task-allow` is the entitlement a development-signed
///   build carries and an App Store build doesn't; the patch writes it false.
///
/// It can't help an app whose check is server-side, or one that inspects the
/// signature's team ID. It also can't patch Swift string literals inlined into
/// code, which is why the report names what was found instead of promising
/// invisibility.
enum SideloadGuard {

    /// Frameworks that mean the app can prove where it was installed from.
    static let attestationFrameworks = ["DeviceCheck", "AppAttest"]

    struct Report {
        var markers: [String] = []
        var frameworks: [String] = []
        /// True when anything was found that a bypass could address.
        var hasPatchable: Bool { !markers.isEmpty }
        /// True when something was found that can't be handled here.
        var hasUnpatchable: Bool { !frameworks.isEmpty }
        var isEmpty: Bool { markers.isEmpty && frameworks.isEmpty }
    }

    /// Reads the build's main executable and reports what it found. Off the
    /// main actor — this is a decompression pass.
    static func scan(_ ipa: URL) -> Report {
        var report = Report()
        guard let archive = IPALibrary.archiveFiles(at: ipa),
              let info = IPAPatch.readInfoPlist(from: ipa) else { return report }

        let executable = (info["CFBundleExecutable"] as? String) ?? ""

        // The libraries it links, for attestation.
        if let binary = executableData(archive: archive, url: ipa, executable: executable) {
            let links = MachOInject.linkedLibraries(in: binary)
            for link in links {
                if let match = attestationFrameworks.first(where: {
                    (link as NSString).lastPathComponent.contains($0)
                }), !report.frameworks.contains(match) {
                    report.frameworks.append(match)
                }
            }
            // Byte search rather than String(decoding:): a 48 MB prefix as a
            // Swift String is another few hundred megabytes of working set for
            // a handful of `contains` checks.
            let bytes = [UInt8](binary)
            for marker in SideloadPatch.markers
                where SideloadPatch.contains(Array(marker.needle.utf8), in: bytes) {
                report.markers.append(marker.label)
            }
        }
        return report
    }

    /// The main executable's bytes, read the same way the injector reads them.
    static func executableData(archive: [IPALibrary.ArchiveFile], url: URL,
                               executable: String) -> Data? {
        guard !executable.isEmpty,
              let entry = archive.first(where: {
                  $0.path.hasSuffix("/" + executable) && $0.path.contains("Payload/")
              }) else { return nil }
        // A bounded read: strings and load commands live well inside the first
        // few tens of megabytes of any real app.
        return IPALibrary.prefix(of: entry, in: url, limit: 24 << 20)
    }
}
