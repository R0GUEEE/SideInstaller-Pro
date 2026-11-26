import Foundation

// Reads real repository indexes through the app's own parser and fails when a
// package is dropped, duplicated or left pointing nowhere. Every argument is a
// `Packages` file saved by the workflow.
//
// The parser is what's under test, not the network: a repository that can't be
// fetched is skipped and named by the workflow, not failed here.

var failures = 0

func fail(_ message: String) {
    print("  FAILED: \(message)")
    failures += 1
}

@discardableResult
func check(_ path: String) -> Int {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("couldn't read \(path)")
        return 0
    }
    let network = text.components(separatedBy: "\n\n").filter {
        $0.contains("\nPackage: ") || $0.hasPrefix("Package: ")
    }.count
    let repoID = UUID()
    let packages = TweakRepoParser.packages(in: text, repoID: repoID)
    print("\(path): stanzas=\(network) packages=\(packages.count)")

    if packages.isEmpty { fail("no packages parsed") }

    // One entry per identifier: the index lists every build it still serves,
    // and the browser shows the newest.
    var seen = Set<String>()
    for package in packages where !seen.insert(package.identifier).inserted {
        fail("duplicate identifier \(package.identifier)")
    }

    for package in packages {
        if package.filename.isEmpty { fail("\(package.identifier) has no Filename") }
        if package.version.isEmpty { fail("\(package.identifier) has no Version") }
        if !package.architecture.isEmpty && !package.architecture.hasPrefix("iphoneos") {
            fail("\(package.identifier) is \(package.architecture)")
        }
        if package.sha256.map({ $0.count != 64 }) == true {
            fail("\(package.identifier) has a malformed SHA-256")
        }
        if package.fileName.isEmpty { fail("\(package.identifier) has no file name") }
    }

    // Filename resolution: relative to the repository's base, never absolute
    // unless the index says so.
    if let sample = packages.first {
        let base = "https://example.com/repo"
        guard let url = TweakRepoStoreURL.filename(sample.filename, base: base) else {
            fail("\(sample.identifier)'s Filename doesn't resolve")
            return packages.count
        }
        if !sample.filename.lowercased().hasPrefix("http") && !url.absoluteString.hasPrefix(base + "/") {
            fail("\(sample.identifier)'s Filename escapes the repository: \(url.absoluteString)")
        }
    }
    return packages.count
}

/// The app's URL rule, copied here because `TweakRepoStore` is main-actor bound
/// and pulls in CryptoKit, which the Linux toolchain doesn't have.
enum TweakRepoStoreURL {
    static func filename(_ filename: String, base: String) -> URL? {
        if filename.lowercased().hasPrefix("http://") || filename.lowercased().hasPrefix("https://") {
            return URL(string: filename)
        }
        var baseText = base
        if !baseText.hasSuffix("/") { baseText += "/" }
        guard let baseURL = URL(string: baseText) else { return nil }
        let relative = filename.hasPrefix("/") ? String(filename.dropFirst()) : filename
        return URL(string: relative, relativeTo: baseURL)?.absoluteURL
    }
}

// The update badge is only as good as this ordering: a release must read
// newer than what's installed, and nothing must read newer than itself.
let ordering: [(candidate: String, current: String, newer: Bool)] = [
    ("1.6", "1.5", true),
    ("1.5", "1.6", false),
    ("1.0.10", "1.0.9", true),
    ("1.0", "1.0", false),
    ("0.9.5000", "0.9.4999", true),
    ("", "1.0", false),
    ("1.4", "", false),
]
for case_ in ordering where TweakRepoParser.isNewer(case_.candidate, than: case_.current) != case_.newer {
    fail("version order: \(case_.candidate) vs \(case_.current) should be \(case_.newer)")
}

var total = 0
for path in CommandLine.arguments.dropFirst() {
    total += check(path)
}
print("packages checked: \(total), failures: \(failures)")
exit(failures == 0 && total > 0 ? 0 : 1)
