import Foundation

/// One Sileo/Cydia repository the tweak browser reads.
///
/// `url` is the directory its `Packages` index and package files are relative
/// to, so `https://repo.chariz.com` rather than `…/Packages`.
struct TweakRepository: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    /// What the repository calls itself (`Label`, then `Origin`), or its host
    /// until the `Release` file has been read.
    var name: String
    var added = Date()
    /// When the index was last read.
    var updated: Date?
    /// How many packages the last read found.
    var count = 0
}

/// One stanza of a repository's `Packages` index, reduced to what a browser
/// needs: what it is, what it says, where its `.deb` is, and what it expects.
struct RepoPackage: Identifiable, Equatable {
    let repoID: UUID
    /// `Package:` — the reverse-DNS name, e.g. `com.leftyfl1p.carbridge`.
    let identifier: String
    let name: String
    let version: String
    let section: String
    let author: String
    let summary: String
    let depends: String
    let architecture: String
    let iconURL: String?
    /// `Filename:` relative to the repository's base URL.
    let filename: String
    let size: Int
    let sha256: String?

    var id: String { repoID.uuidString + "|" + identifier }

    /// A rootless build is `iphoneos-arm64`, a rootful one `iphoneos-arm`; both
    /// work, since only the library inside the package is taken.
    var isModern: Bool { architecture.isEmpty || architecture.hasSuffix("arm64") }

    /// The name the `.deb` gets on disk, which is also how the configuration
    /// recognises a copy it already has.
    var fileName: String {
        let last = (filename as NSString).lastPathComponent
        return last.isEmpty ? "\(identifier).deb" : last
    }

    var sizeText: String {
        guard size > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// Reads the `Packages` index a Sileo/Cydia repository publishes.
///
/// The format is Debian's: stanzas of `Key: value` lines separated by blank
/// lines, with continuation lines that belong to the key above them (a long
/// `Description` is the common case).
enum TweakRepoParser {

    /// Every package the index describes, one entry per identifier — the newest
    /// version wins, since a repository lists every build it still serves.
    static func packages(in text: String, repoID: UUID) -> [RepoPackage] {
        var best: [String: RepoPackage] = [:]
        for fields in stanzas(in: text) {
            guard let identifier = fields["package"], !identifier.isEmpty,
                  let filename = fields["filename"], !filename.isEmpty
            else { continue }

            let architecture = fields["architecture"] ?? ""
            // Repositories can serve macOS or Debian builds from the same
            // index; only iOS ones can be injected here.
            if !architecture.isEmpty, !architecture.hasPrefix("iphoneos") { continue }

            let package = RepoPackage(repoID: repoID,
                                      identifier: identifier,
                                      name: fields["name"]?.nilIfEmpty ?? identifier,
                                      version: fields["version"] ?? "",
                                      section: fields["section"]?.nilIfEmpty ?? "",
                                      author: (fields["author"] ?? fields["maintainer"] ?? "").nilIfEmpty ?? "",
                                      summary: fields["description"]?.nilIfEmpty ?? "",
                                      depends: fields["depends"]?.nilIfEmpty ?? "",
                                      architecture: architecture,
                                      iconURL: fields["icon"]?.nilIfEmpty,
                                      filename: filename,
                                      size: Int(fields["size"] ?? "") ?? 0,
                                      sha256: fields["sha256"]?.nilIfEmpty?.lowercased())

            if let existing = best[identifier] {
                let order = compare(package.version, existing.version)
                // The newest version wins; the same version built for a
                // rootless jailbreak (arm64) is preferred over a rootful one.
                if order == .orderedDescending
                    || (order == .orderedSame
                        && package.architecture.hasSuffix("arm64")
                        && !existing.architecture.hasSuffix("arm64")) {
                    best[identifier] = package
                }
            } else {
                best[identifier] = package
            }
        }
        return best.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// What a repository's `Release` file says it's called.
    static func label(in release: String) -> String? {
        for fields in stanzas(in: release) {
            if let label = fields["label"]?.nilIfEmpty { return label }
            if let origin = fields["origin"]?.nilIfEmpty { return origin }
        }
        return nil
    }

    /// True when `candidate` is a newer package version than `current`.
    ///
    /// The order is Debian's for the numbered versions repositories actually
    /// publish (`1.0.10` after `1.0.9`); the one place it differs is `~`, which
    /// Debian sorts before an empty string (`1.0~beta` < `1.0`) and this treats
    /// as punctuation. A pre-release that relies on the tilde (`1.0~beta`) can
    /// therefore read as newer than its own release, so the update it offers is
    /// a downgrade; every other ordering is Debian's.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard !candidate.isEmpty, !current.isEmpty else { return false }
        return compare(candidate, current) == .orderedDescending
    }

    private static func stanzas(in text: String) -> [[String: String]] {
        let normalized = text.contains("\r\n")
            ? text.replacingOccurrences(of: "\r\n", with: "\n")
            : text
        var out: [[String: String]] = []
        var fields: [String: String] = [:]
        var lastKey: String?
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.isEmpty {
                if !fields.isEmpty {
                    out.append(fields)
                    fields = [:]
                    lastKey = nil
                }
                continue
            }
            if raw.hasPrefix(" ") || raw.hasPrefix("\t") {
                guard let lastKey else { continue }
                fields[lastKey] = (fields[lastKey] ?? "") + "\n"
                    + raw.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = raw[raw.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
            lastKey = key
        }
        if !fields.isEmpty { out.append(fields) }
        return out
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}

private extension String {
    /// A field that was present but empty is the same as one that's missing.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
