import Foundation

/// Where each injection framework can be fetched from, and how.
///
/// ElleKit and Substitute are open source and publish builds; CydiaSubstrate
/// and libhooker don't, so those two can only be added from a copy the user
/// already has.
enum InjectorCatalog {

    /// Where a framework's build comes from.
    enum Source {
        /// A Sileo/Cydia-style repository: its `Packages` index lists `.deb`
        /// files, and the newest `iphoneos-arm64` build is taken.
        case repository(index: String)
        /// A GitHub repository whose releases carry a `.deb` or `.dylib`.
        case gitHub(owner: String, repo: String)
    }

    struct Entry {
        let kind: TweakInjectorKind
        let source: Source?
        /// Why there's no source, when there isn't one.
        let note: String
    }

    static func entry(for kind: TweakInjectorKind) -> Entry {
        switch kind {
        case .ellekit:
            return Entry(kind: kind,
                         source: .repository(index: "https://dhinakg.github.io/ellekit-repo/Packages"),
                         note: L("Open source. Fetched from the community ElleKit repository as a .deb, and the library taken out of it."))
        case .substitute:
            return Entry(kind: kind,
                         source: .gitHub(owner: "comex", repo: "substitute"),
                         note: L("Open source. Fetched from its GitHub release."))
        case .substrate:
            return Entry(kind: kind, source: nil,
                         note: L("Closed source, so there's no build to download. Add a copy you have."))
        case .libhooker:
            return Entry(kind: kind, source: nil,
                         note: L("No published build. Add a copy you have."))
        }
    }

    enum FetchError: LocalizedError {
        case noSource(TweakInjectorKind)
        case unreachable(String)
        case notFound(TweakInjectorKind)
        case noLibrary(String)
        case damaged(String)

        var errorDescription: String? {
            switch self {
            case .noSource(let kind):
                return L("%@ has no published build to download — add a copy you have.", kind.title)
            case .unreachable(let reason):
                return L("Couldn't reach the download: %@", reason)
            case .notFound(let kind):
                return L("No %@ build was found where it's usually published.", kind.title)
            case .noLibrary(let name):
                return L("%@ unpacked, but it carries no library SideInstaller can inject.", name)
            case .damaged(let reason):
                return L("The downloaded file couldn't be read: %@", reason)
            }
        }
    }

    /// Downloads and unpacks a framework, returning the library to store.
    static func fetch(_ kind: TweakInjectorKind) async throws -> (data: Data, fileName: String) {
        guard let source = entry(for: kind).source else { throw FetchError.noSource(kind) }
        switch source {
        case .repository(let index):
            let (packageURL, archive) = try await newestPackage(in: index, matching: kind)
            let (data, name) = try unpack(archive, kind: kind, preferred: ["ellekit"],
                                          fallbackName: packageURL.lastPathComponent)
            return (data, name)
        case .gitHub(let owner, let repo):
            let archive = try await gitHubAsset(owner: owner, repo: repo)
            let (data, name) = try unpack(archive.data, kind: kind,
                                          preferred: [kind.packageName, "substitute"],
                                          fallbackName: archive.name)
            return (data, name)
        }
    }

    // MARK: Sileo-style repository

    /// Reads a repo's `Packages` index and returns the newest package's `.deb`.
    private static func newestPackage(in index: String,
                                      matching kind: TweakInjectorKind) async throws -> (URL, Data) {
        guard let indexURL = URL(string: index) else { throw FetchError.damaged(index) }
        let (raw, response) = try await get(indexURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetchError.unreachable("HTTP \(http.statusCode)")
        }
        let text = String(decoding: raw, as: UTF8.self)
        var candidates: [(version: String, filename: String, architecture: String)] = []
        for stanza in text.components(separatedBy: "\n\n") {
            var fields: [String: String] = [:]
            for line in stanza.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.startIndex..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let filename = fields["filename"], let version = fields["version"] else { continue }
            let architecture = fields["architecture"] ?? ""
            guard architecture == "iphoneos-arm64" || architecture == "iphoneos-arm" else { continue }
            // Every stanza in this index is ElleKit; a repository with more than
            // one package would need its `Package:` field to choose.
            if let name = fields["package"], !name.lowercased().contains(kind.packageName),
               kind == .ellekit, !name.lowercased().contains("ellekit") { continue }
            candidates.append((version, filename, architecture))
        }
        guard let best = candidates.max(by: { compare($0.version, $1.version) == .orderedAscending })
        else { throw FetchError.notFound(kind) }

        // A repo's Filename is relative to the index's directory.
        let relative = best.filename.hasPrefix("./") ? String(best.filename.dropFirst(2)) : best.filename
        guard let url = URL(string: relative, relativeTo: indexURL.deletingLastPathComponent()) else {
            throw FetchError.damaged(best.filename)
        }
        let (debData, debResponse) = try await get(url)
        if let http = debResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetchError.unreachable("HTTP \(http.statusCode)")
        }
        return (url, debData)
    }

    // MARK: GitHub releases

    /// The first `.deb` (or `.dylib`) on the newest release.
    private static func gitHubAsset(owner: String, repo: String) async throws -> (name: String, data: Data) {
        guard let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases") else {
            throw FetchError.damaged("\(owner)/\(repo)")
        }
        let (raw, _) = try await get(api, accept: "application/vnd.github+json",
                                     authorization: nil)
        guard let releases = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else {
            throw FetchError.notFound(.substitute)
        }
        for release in releases {
            let assets = release["assets"] as? [[String: Any]] ?? []
            // A .deb first: it carries the versioned library and its layout.
            let ordered = assets.sorted { lhs, rhs in
                let a = (lhs["name"] as? String ?? "").lowercased()
                let b = (rhs["name"] as? String ?? "").lowercased()
                return a.hasSuffix(".deb") && !b.hasSuffix(".deb")
            }
            for asset in ordered {
                guard let name = asset["name"] as? String,
                      let link = asset["browser_download_url"] as? String,
                      let url = URL(string: link),
                      name.lowercased().hasSuffix(".deb") || name.lowercased().hasSuffix(".dylib")
                else { continue }
                let (data, _) = try await get(url)
                return (name, data)
            }
        }
        throw FetchError.notFound(.substitute)
    }

    // MARK: Shared

    /// Takes the library out of a downloaded `.deb`, or passes a `.dylib`
    /// straight through.
    private static func unpack(_ archive: Data, kind: TweakInjectorKind,
                               preferred: [String], fallbackName: String) throws -> (Data, String) {
        if (fallbackName as NSString).pathExtension.lowercased() == "dylib" {
            return (archive, fallbackName)
        }
        // DebArchive reads a file, so the download lands in temp first.
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("injector-\(UUID().uuidString).deb")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try archive.write(to: temporary, options: .atomic)
            let package = try DebArchive.read(temporary)
            let lowered = preferred.map { $0.lowercased() }
            let match = package.libraries.first { library in
                let name = library.fileName.lowercased()
                return lowered.contains { name.contains($0) }
            } ?? package.libraries.first
            guard let match else { throw FetchError.noLibrary(fallbackName) }
            return (match.data, match.fileName)
        } catch let error as DebArchive.DebError {
            throw FetchError.damaged(error.localizedDescription)
        }
    }

    private static func get(_ url: URL, accept: String? = nil,
                            authorization: String? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 40
        request.setValue("SideInstaller", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw FetchError.unreachable(error.localizedDescription)
        }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}
