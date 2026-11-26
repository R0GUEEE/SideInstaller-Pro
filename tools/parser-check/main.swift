import Foundation

func L(_ key: String) -> String { key }
func L(_ key: String, _ arguments: CVarArg...) -> String { key }

// Every argument is a repository document. Each must yield at least one app,
// and none of its app-shaped items may be dropped.
var failures = 0
for path in CommandLine.arguments.dropFirst() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        print("FAILED to read \(path)")
        failures += 1
        continue
    }
    let format = SourceParser.format(of: data)
    guard let parsed = SourceParser.parse(data, sourceName: "check", sourceID: path) else {
        print("\(path): FAILED — no apps parsed (format: \(format.rawValue))")
        failures += 1
        continue
    }
    let noVersion = parsed.entries.filter { $0.versions.isEmpty }.count
    print("\(path): format=\(format.rawValue) apps=\(parsed.entries.count) "
          + "withReleases=\(parsed.entries.count - noVersion) "
          + "name=\(parsed.name ?? "-")")
    if parsed.entries.isEmpty { failures += 1 }
    if noVersion > 0 {
        print("  FAILED: \(noVersion) app(s) without a release")
        failures += 1
    }
}
exit(failures == 0 ? 0 : 1)
