import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Reading a GitHub repository's releases as a source. Split from SourceKind so
// the models there compile where URLSession doesn't exist (the Linux parser
// check); the app itself always has it.

// MARK: - GitHub releases as a source

/// A GitHub repository read as a source: every `.ipa` on its releases, newest
/// first, becomes an app.
///
/// Some IPAs get their own app each (different bundle IDs); one repository that
/// keeps re-releasing the same app becomes one app with one release per tag.
enum GitHubSource {

    struct Release {
        let tag: String
        let name: String?
        let published: Date?
        let body: String?
        let assets: [(name: String, url: URL, size: Int64, date: Date?)]
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Reads `owner/repo` from a github.com link.
    static func repo(from url: URL) -> (owner: String, repo: String)? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var owner = parts[0]
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        if owner == "www" { owner = parts[0] }
        return (owner, repo)
    }

    /// Fetches the releases and turns their `.ipa` assets into market entries.
    static func entries(owner: String, repo: String, sourceName: String) async throws -> [MarketEntry] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=30")!)
        request.timeoutInterval = 25
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SideInstaller", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 403 || http.statusCode == 429 {
                throw Failure(message: L("GitHub is rate-limiting this iPhone. Try again in a few minutes, or add the repository as an AltStore source instead."))
            }
            guard (200...299).contains(http.statusCode) else {
                throw Failure(message: L("GitHub answered %ld for %@/%@.", http.statusCode, owner, repo))
            }
        }
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !releases.isEmpty else {
            throw Failure(message: L("%@/%@ has no releases.", owner, repo))
        }

        let formatter = ISO8601DateFormatter()
        let sourceID = "github:\(owner)/\(repo)"
        var byApp: [String: MarketEntry] = [:]
        var order: [String] = []

        for raw in releases {
            guard let tag = raw["tag_name"] as? String else { continue }
            let published = (raw["published_at"] as? String ?? raw["created_at"] as? String)
                .flatMap { formatter.date(from: $0) }
            let body = raw["body"] as? String
            let assets = (raw["assets"] as? [[String: Any]] ?? []).compactMap { asset -> (String, URL, Int64, Date?)? in
                guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".ipa"),
                      let link = asset["browser_download_url"] as? String, let url = URL(string: link)
                else { return nil }
                let updated = (asset["updated_at"] as? String).flatMap { formatter.date(from: $0) }
                return (name, url, Int64(asset["size"] as? Int ?? 0), updated)
            }
            guard let asset = assets.first else { continue }

            // The asset's own name is the only identity a release feed has.
            let stem = (asset.0 as NSString).deletingPathExtension
            let key = stem.lowercased()
            let version = MarketEntry.Version(id: asset.1.absoluteString,
                                              version: tag,
                                              date: published ?? asset.3,
                                              size: asset.2,
                                              url: asset.1.absoluteString,
                                              minOS: nil,
                                              sourceID: sourceID,
                                              sourceName: sourceName)
            if var existing = byApp[key] {
                existing.versions.append(version)
                existing.versions.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                byApp[key] = existing
            } else {
                byApp[key] = MarketEntry(id: "\(sourceID)#\(key)",
                                         name: stem,
                                         developer: owner,
                                         subtitle: body?.split(separator: "\n").first.map(String.init),
                                         icon: "https://github.com/\(owner).png?size=120",
                                         category: "",
                                         versions: [version])
                order.append(key)
            }
        }
        guard !byApp.isEmpty else {
            throw Failure(message: L("%@/%@ has no releases with an .ipa.", owner, repo))
        }
        return order.compactMap { byApp[$0] }
    }
}
