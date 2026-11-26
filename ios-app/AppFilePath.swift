import Foundation

/// AFC paths are absolute, component checked, and never resolved through links.
enum AppFilePath {
    static func valid(_ path: String, root: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        if path != "/" && path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return false }
        return root == "/" || path == root || path.hasPrefix(root + "/")
    }
    static func child(_ name: String, of parent: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        return (parent == "/" ? "" : parent) + "/" + name
    }
    static func deletable(_ path: String, root: String) -> Bool {
        valid(path, root: root) && !["/", "/Documents", "/Library", "/Library/Caches", "/tmp"].contains(path)
    }
}

struct AppFileEntry: Identifiable {
    let path: String
    let name: String
    let size: Int64
    let kind: String
    var id: String { path }
    var isDirectory: Bool { kind == "S_IFDIR" }
    var isLink: Bool { kind == "S_IFLNK" }
}
