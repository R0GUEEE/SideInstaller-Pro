import Foundation

// Stand-in for the app's localisation lookup: the harness has no language
// tables, and the messages only matter on device.
func L(_ key: String) -> String { key }
func L(_ key: String, _ arguments: CVarArg...) -> String { key }

// Configuration and plist editor regression checks run before archive tests.
do {
    var saved = AppConfig()
    saved.plistEdits = [PlistEdit(key: "UIBackgroundModes", kind: .array, value: "audio, fetch")]
    let loaded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(saved))
    precondition(loaded.schema == 3 && loaded.plistEdits == saved.plistEdits)
    precondition(PlistEdit.Kind.editable(["audio", "fetch"]))
    precondition(!PlistEdit.Kind.editable(["a,b"]))
    precondition(!PlistEdit.Kind.editable(["nested": "dictionary"]))
    precondition(!PlistEdit.Kind.editable(1.25))
    precondition(!PlistEdit.Kind.editable(Data([1, 2])))
}

// Arguments: <ipa> <tweak.dylib> [deb] [deb]
guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: patch-selftest <ipa> <tweak.dylib> [deb]\n".utf8))
    exit(64)
}
let ipa = URL(fileURLWithPath: CommandLine.arguments[1])
let tweak = CommandLine.arguments[2]

var config = AppConfig()
config.bundleIdentifier = "com.example.renamed"
config.displayName = "Renamed App"
config.version = "9.9"
config.build = "42"
config.stripWatchApp = true
config.tweaks = [Tweak(name: "TestTweak.dylib",
                       path: tweak,
                       kind: .dylib,
                       loadPath: "@executable_path/Frameworks/TestTweak.dylib")]

do {
    let outcome = try IPAPatch.apply(config, injectors: [], to: ipa)
    print("APPLIED")
    for line in outcome.applied { print("  + \(line)") }
    for line in outcome.warnings { print("  ! \(line)") }
} catch {
    print("FAILED: \(error.localizedDescription)")
    exit(1)
}

// The archived entitlements the applied configuration declares: the run above
// had no entitlement edits, so anything there is the app's own declaration.
do {
    var edited = config
    edited.entitlements = [PlistEdit(key: "com.apple.developer.kernel.increased-memory-limit",
                                     kind: .boolean, value: "true")]
    _ = try IPAPatch.apply(edited, injectors: [], to: ipa)
    guard let entitlements = IPAPatch.readEntitlements(from: ipa) else {
        print("FAILED: no entitlements found in the patched archive")
        exit(1)
    }
    if entitlements["keychain-access-groups"] == nil {
        print("FAILED: the keychain access group was not written")
        exit(1)
    }
    if entitlements["com.apple.developer.kernel.increased-memory-limit"] == nil {
        print("FAILED: a configured entitlement was not written")
        exit(1)
    }
}

// A second pass must be a no-op: same identity, same tweak, nothing rewritten.
do {
    let second = try IPAPatch.apply(config, injectors: [], to: ipa)
    print("SECOND PASS")
    for line in second.applied { print("  + \(line)") }
    for line in second.warnings { print("  ! \(line)") }
    if second.applied.contains(where: { $0.contains("Injected") }) {
        print("FAILED: the tweak was injected twice")
        exit(1)
    }
} catch {
    print("FAILED on the second pass: \(error.localizedDescription)")
    exit(1)
}

// A `.deb`, when one is given: the package fields and the libraries that would
// be injected out of it.
if CommandLine.arguments.count >= 4 {
    do {
        let package = try DebArchive.read(URL(fileURLWithPath: CommandLine.arguments[3]))
        print("DEB PACKAGE: \(package.identifier ?? "-")/\(package.name ?? "-")/\(package.version ?? "-")/\(package.architecture ?? "-")")
        print("DEB DEPENDS: \(package.depends ?? "-")")
        print("DEB INJECTOR: \(package.requiredInjector?.rawValue ?? "none")")
        for library in package.libraries {
            print("DEB LIB: \(library.path) -> \(library.fileName) (\(library.data.count) bytes)")
        }
        if package.libraries.isEmpty {
            print("FAILED: the package carried no library")
            exit(1)
        }
    } catch {
        print("FAILED reading the deb: \(error.localizedDescription)")
        exit(1)
    }
}

// Self-declared entitlements: what the app may write without a profile.
do {
    let declared = IPAPatch.selfDeclaredEntitlements(for: "com.example.app.TEAMID")
    guard let groups = declared["keychain-access-groups"] as? [String],
          groups == ["com.example.app.TEAMID"] else {
        print("FAILED: the app is not given its own keychain access group")
        exit(1)
    }
    if declared.keys.contains(where: { $0.hasPrefix("com.apple.developer.") }) {
        print("FAILED: a profile-granted entitlement was declared by the app")
        exit(1)
    }
    if !IPAPatch.selfDeclaredEntitlements(for: "").isEmpty {
        print("FAILED: an app with no identifier was given entitlements")
        exit(1)
    }
    print("ENTITLEMENTS: self-declared set is keychain groups only")
}

// Extension identifiers and entitlements: what "the extension is signed
// properly" comes down to. These are pure functions, so they're checked
// directly rather than through an archive.
do {
    let appBefore = "com.example.app"
    let appAfter = "com.example.renamed"

    // Its own name survives a rename.
    let kept = IPAPatch.nestedIdentifier(current: "com.example.app.Widget",
                                         appBefore: appBefore, appAfter: appAfter,
                                         stem: "RenamedWidget", isWatch: false)
    if kept != "com.example.renamed.Widget" {
        print("FAILED: extension kept the wrong identifier through a rename: \(kept)")
        exit(1)
    }

    // An identifier outside the app's is re-prefixed from the folder.
    let fixed = IPAPatch.nestedIdentifier(current: "com.other.widget",
                                          appBefore: appBefore, appAfter: appAfter,
                                          stem: "Widget", isWatch: false)
    if fixed != "com.example.renamed.Widget" {
        print("FAILED: stray extension identifier wasn't fixed: \(fixed)")
        exit(1)
    }

    // A watch app gets its own suffix rule.
    let watch = IPAPatch.nestedIdentifier(current: "", appBefore: appBefore,
                                          appAfter: appAfter, stem: "WatchApp", isWatch: true)
    if watch != "com.example.renamed.WatchApp.watchkitapp" {
        print("FAILED: watch identifier wrong: \(watch)")
        exit(1)
    }

    let unchanged = IPAPatch.nestedIdentifier(current: "com.other.widget",
                                             appBefore: appBefore, appAfter: appBefore,
                                             stem: "Widget", isWatch: false)
    if unchanged != "com.other.widget" { fatalError("Unchanged parent rewrote nested ID") }
    print("EXTENSIONS: identifier checks passed")
}
