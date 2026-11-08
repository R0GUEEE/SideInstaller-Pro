import Foundation

/// What the signed bundle says about itself, read back from disk.
///
/// The signer is the only thing that writes the signature, so the interesting
/// question afterwards is whether the result matches the profiles: every
/// executable carries a signature, the app and each extension carry a
/// `embedded.mobileprovision`, and each `.mobileprovision` grants the
/// identifier of the bundle it sits in. This reads all of that back without
/// attacking the CMS envelope — the profile's plist is the same XML blob the
/// signer parsed — so a mistake shows up in the log before the app is installed
/// rather than as a crash on the device.
enum SignedBundleAudit {

    struct Result {
        var problems: [String] = []
        var notes: [String] = []
        /// One line per bundle, for the log.
        var summary: [String] = []
    }

    /// Audits the `.app` at `appPath` against the identifiers it was signed for.
    static func run(appPath: String) -> Result {
        var result = Result()
        let root = URL(fileURLWithPath: appPath)
        let manager = FileManager.default

        guard let appID = plistValue(in: root)?["CFBundleIdentifier"] as? String else {
            result.problems.append("the signed app has no readable Info.plist")
            return result
        }
        result.summary.append("\(root.lastPathComponent): \(appID)")

        var identifiers: [(String, URL)] = [(appID, root)]
        var stack = [root]
        var depth = 0
        while !stack.isEmpty, depth < 8 {
            var next: [URL] = []
            for dir in stack {
                for folder in ["PlugIns", "Frameworks"] {
                    let base = dir.appendingPathComponent(folder)
                    guard let entries = try? manager.contentsOfDirectory(at: base,
                                                                        includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                    for entry in entries {
                        guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                        let ext = entry.pathExtension.lowercased()
                        if ext == "appex" || ext == "framework" {
                            if let id = plistValue(in: entry)?["CFBundleIdentifier"] as? String {
                                identifiers.append((id, entry))
                                result.summary.append("  \(entry.lastPathComponent): \(id)")
                            }
                        }
                        if ext == "appex" || ext == "framework" || ext == "app" {
                            next.append(entry)
                        }
                    }
                }
            }
            stack = next
            depth += 1
        }

        for (id, bundle) in identifiers {
            let info = plistValue(in: bundle) ?? [:]
            let executableName = info["CFBundleExecutable"] as? String
            if let executableName {
                let executable = bundle.appendingPathComponent(executableName)
                if !hasSignature(executable) {
                    result.problems.append("\(bundle.lastPathComponent) has no code signature")
                }
            }
            let ext = bundle.pathExtension.lowercased()
            if ext == "app" || ext == "appex" {
                let profile = bundle.appendingPathComponent("embedded.mobileprovision")
                guard let data = try? Data(contentsOf: profile) else {
                    result.problems.append("\(bundle.lastPathComponent) has no embedded.mobileprovision")
                    continue
                }
                guard let granted = profileEntitlements(in: data)?["application-identifier"] as? String else {
                    result.notes.append("\(bundle.lastPathComponent)'s profile doesn't name an application-identifier")
                    continue
                }
                if !covers(granted, id) {
                    result.problems.append("\(bundle.lastPathComponent) is \(id) but its profile grants \(granted)")
                }
            }
        }

        if result.problems.isEmpty {
            result.notes.append("signature check passed for \(identifiers.count) bundle(s)")
        }
        return result
    }

    /// True when a Mach-O at `url` ends in a `LC_CODE_SIGNATURE` whose blob is a
    /// superblob: the signature the signer wrote, not a leftover header.
    private static func hasSignature(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 32 else { return false }
        let magic = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        // Thin little-endian 64-bit (0xfeedfacf as bytes cf fa ed fe) is what an
        // iOS app's executable is; fat binaries are handled by their first arch.
        let isThin = magic == 0xfeedfacf || magic == 0xfeedface
        let isFat = magic == 0xcafebabe || magic == 0xbebafeca
        var offset: UInt64 = 0
        var ncmds: UInt32 = 0
        var sizeofcmds: UInt32 = 0
        if isThin {
            guard head.count >= 32 else { return false }
            ncmds = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
            sizeofcmds = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
            offset = 32
        } else if isFat {
            guard head.count >= 24 else { return false }
            let archOffset = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
            offset = UInt64(archOffset)
            guard let nested = try? handle.read(from: offset, count: 32), nested.count >= 32 else { return false }
            ncmds = nested.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
            sizeofcmds = nested.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
            offset += 32
        } else {
            return false
        }
        let limit = min(Int(sizeofcmds), 1 << 20)
        guard ncmds > 0, limit > 0,
              let commands = try? handle.read(from: offset, count: limit) else { return false }
        var cursor = 0
        for _ in 0..<ncmds {
            guard cursor + 8 <= commands.count else { break }
            let cmd = commands.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) }
            let size = commands.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self) }
            if cmd == 0x1d /* LC_CODE_SIGNATURE */, size >= 16, cursor + 16 <= commands.count {
                let dataoff = commands.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 8, as: UInt32.self) }
                let datasize = commands.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 12, as: UInt32.self) }
                guard datasize >= 12, let magicBlob = try? handle.read(from: UInt64(dataoff), count: 4),
                      magicBlob.count == 4 else { return false }
                let blobMagic = magicBlob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
                return blobMagic == 0xfade0cc0 // CSMAGIC_EMBEDDED_SIGNATURE
            }
            guard size >= 8 else { break }
            cursor += Int(size)
        }
        return false
    }

    private static func covers(_ applicationIdentifier: String, _ bundleID: String) -> Bool {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else { return false }
        let appID = String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
        if appID == "*" { return true }
        if appID.hasSuffix(".*") {
            let prefix = String(appID.dropLast(2))
            return bundleID == prefix || bundleID.hasPrefix(prefix + ".")
        }
        return bundleID == appID || bundleID.hasPrefix(appID + ".")
    }

    private static func plistValue(in bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// The `Entitlements` dictionary of a `.mobileprovision`, found the way the
    /// rest of the app finds it: the XML plist inside Apple's CMS wrapper.
    private static func profileEntitlements(in data: Data) -> [String: Any]? {
        let start = Data("<?xml".utf8)
        let end = Data("</plist>".utf8)
        guard let from = data.range(of: start),
              let to = data.range(of: end, options: [], in: from.lowerBound..<data.endIndex) else { return nil }
        let body = data[from.lowerBound..<to.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: body, format: nil)
            as? [String: Any] else { return nil }
        return plist["Entitlements"] as? [String: Any]
    }
}

private extension FileHandle {
    func read(from offset: UInt64, count: Int) throws -> Data? {
        try seek(toOffset: offset)
        return try read(upToCount: count)
    }
}
