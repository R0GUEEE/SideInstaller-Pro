import Foundation

@main struct AppFilesRegression {
    static func main() {
        for bad in ["", "Documents", "/Documents/../Library", "/Documents//file", "/Documents/./file", "/Documents/a/", "/Documents/evil\0name", "/DocumentsOther/file"] {
            precondition(!AppFilePath.valid(bad, root: "/Documents"), "Accepted unsafe path: \(bad)")
        }
        for good in ["/Documents", "/Documents/folder", "/Documents/folder/file.txt", "/Documents/日本語"] {
            precondition(AppFilePath.valid(good, root: "/Documents"))
        }
        precondition(AppFilePath.valid("/", root: "/"))
        for root in ["/", "/Documents", "/Library", "/Library/Caches", "/tmp"] {
            precondition(!AppFilePath.deletable(root, root: "/"))
        }
        precondition(AppFilePath.deletable("/Documents/file", root: "/Documents"))
        precondition(!AppFilePath.deletable("/Library/file", root: "/Documents"))
        for bad in [".", "..", "", "a/b", "a\0b"] { precondition(AppFilePath.child(bad, of: "/") == nil) }
        precondition(AppFilePath.child("file", of: "/") == "/file")
        precondition(AppFilePath.child("file", of: "/Documents") == "/Documents/file")
        print("App file path safety checks passed")
    }
}
