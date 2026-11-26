import Foundation

/// A documented `Info.plist` key: what it does, what type it takes, and the
/// values Apple defines for it.
///
/// The configuration page uses this for completions (type a few letters, pick
/// the key) and to draw the right editor — a switch for a boolean, a picker for
/// an enumeration, a list editor for the array keys.
struct PlistKeySpec: Identifiable, Hashable {
    let key: String
    let kind: PlistEdit.Kind
    /// One line, in Apple's words where it's short enough.
    let summary: String
    /// Values Apple documents for the key, when it's an enumeration.
    let values: [String]

    var id: String { key }

    init(_ key: String, _ kind: PlistEdit.Kind, _ summary: String, values: [String] = []) {
        self.key = key
        self.kind = kind
        self.summary = summary
        self.values = values
    }
}

/// The keys worth offering by name. Not every key in the format — the ones a
/// sideloaded build actually gets changed for, plus the common privacy strings.
enum PlistCatalog {

    static let all: [PlistKeySpec] = [
        // Identity
        .init("CFBundleIdentifier", .string, L("The bundle ID iOS registers and signs.")),
        .init("CFBundleDisplayName", .string, L("The name on the Home Screen.")),
        .init("CFBundleName", .string, L("The short name, used where space is tight.")),
        .init("CFBundleShortVersionString", .string, L("The version shown in Settings and App Store Connect.")),
        .init("CFBundleVersion", .string, L("The build number, which must climb with every upload.")),
        .init("MinimumOSVersion", .string, L("The oldest iOS the app installs on — also checked by the App Store.")),
        .init("LSMinimumSystemVersion", .string, L("macOS-only equivalent of MinimumOSVersion.")),
        .init("CFBundleDevelopmentRegion", .string, L("The language the bundle's own strings are in.")),

        // Interface
        .init("UIUserInterfaceStyle", .string, L("Force light or dark, whatever the system is set to."),
              values: ["Automatic", "Light", "Dark"]),
        .init("UIStatusBarStyle", .string, L("The status bar's content colour."),
              values: ["UIStatusBarStyleDefault", "UIStatusBarStyleLightContent"]),
        .init("UIStatusBarHidden", .boolean, L("Hide the status bar entirely.")),
        .init("UIViewControllerBasedStatusBarAppearance", .boolean,
              L("Let each view controller choose the status bar style.")),
        .init("UIRequiresFullScreen", .boolean,
              L("Opt out of iPad multitasking; also what a lot of games need.")),
        .init("UIApplicationSupportsIndirectInputEvents", .boolean,
              L("Trackpad and mouse support, which iOS expects modern apps to opt into.")),
        .init("UIApplicationSupportsMultipleScenes", .boolean, L("Allow more than one window of the app.")),
        .init("UISupportedInterfaceOrientations", .array,
              L("The orientations the app allows on iPhone."),
              values: ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                       "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]),
        .init("UISupportedInterfaceOrientations~ipad", .array,
              L("The orientations the app allows on iPad."),
              values: ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                       "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]),
        .init("UIDeviceFamily", .array,
              L("Which devices the app installs on."),
              values: ["1", "2", "3", "6"]),

        // Capabilities and background work
        .init("UIRequiredDeviceCapabilities", .array,
              L("Hardware the app insists on; the install is refused without it."),
              values: ["arm64", "armv7", "gps", "gamekit", "metal", "magnetometer",
                       "microphone", "nfc", "accelerometer", "gyroscope", "telephony"]),
        .init("UIBackgroundModes", .array,
              L("What the app may keep doing in the background."),
              values: ["audio", "location", "voip", "fetch", "remote-notification",
                       "processing", "bluetooth-central", "bluetooth-peripheral", "external-accessory"]),

        // Documents and sharing
        .init("UIFileSharingEnabled", .boolean, L("Show the app's Documents folder in the Files app.")),
        .init("LSSupportsOpeningDocumentsInPlace", .boolean,
              L("Open documents where they are rather than copying them in.")),
        .init("UISupportsDocumentBrowser", .boolean, L("Let the app work as a document browser.")),
        .init("UIAppFonts", .array, L("Font files in the bundle to register at launch.")),
        .init("UIPrerenderedIcon", .boolean, L("Legacy: the icon already has its gloss.")),

        // URLs and links
        .init("LSApplicationQueriesSchemes", .array,
              L("URL schemes the app may test for with canOpenURL.")),
        .init("CFBundleURLTypes", .array,
              L("URL schemes the app answers to, as dictionaries (see Apple's CFBundleURLTypes).")),

        // Privacy strings — an app crashes on first use without these
        .init("NSCameraUsageDescription", .string, L("Shown when the app asks for the camera.")),
        .init("NSMicrophoneUsageDescription", .string, L("Shown when the app asks for the microphone.")),
        .init("NSPhotoLibraryUsageDescription", .string, L("Shown when the app asks for the photo library.")),
        .init("NSPhotoLibraryAddUsageDescription", .string, L("Shown when the app saves to the photo library.")),
        .init("NSContactsUsageDescription", .string, L("Shown when the app asks for contacts.")),
        .init("NSCalendarsUsageDescription", .string, L("Shown when the app asks for calendars.")),
        .init("NSRemindersUsageDescription", .string, L("Shown when the app asks for reminders.")),
        .init("NSLocationWhenInUseUsageDescription", .string, L("Shown when the app asks for location while in use.")),
        .init("NSLocationAlwaysAndWhenInUseUsageDescription", .string, L("Shown when the app asks for location in the background.")),
        .init("NSBluetoothAlwaysUsageDescription", .string, L("Shown when the app asks for Bluetooth.")),
        .init("NSLocalNetworkUsageDescription", .string, L("Shown when the app looks for devices on the local network.")),
        .init("NSBonjourServices", .array, L("Bonjour service types the app browses for.")),
        .init("NSFaceIDUsageDescription", .string, L("Shown when the app asks for Face ID.")),
        .init("NSHealthShareUsageDescription", .string, L("Shown when the app reads Health data.")),
        .init("NSHealthUpdateUsageDescription", .string, L("Shown when the app writes Health data.")),
        .init("NSSpeechRecognitionUsageDescription", .string, L("Shown when the app asks for speech recognition.")),
        .init("NSUserTrackingUsageDescription", .string, L("Shown when the app asks to track across apps.")),
        .init("NSMotionUsageDescription", .string, L("Shown when the app asks for motion data.")),

        // Security and App Store metadata
        .init("ITSAppUsesNonExemptEncryption", .boolean, L("Export compliance for App Store uploads.")),
        .init("UIApplicationExitsOnSuspend", .boolean, L("Legacy: quit instead of suspending.")),
        .init("UILaunchScreen", .array, L("The launch screen, as a dictionary (see Apple's UILaunchScreen).")),
    ]

    private static let index = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

    static func spec(for key: String) -> PlistKeySpec? { index[key] }

    /// Keys matching what's been typed: prefix first, then contains, so typing
    /// `UIFile` reaches `UIFileSharingEnabled` before `NSFileProvider…`-style
    /// matches.
    static func matching(_ text: String) -> [PlistKeySpec] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        let lowered = query.lowercased()
        let prefixed = all.filter { $0.key.lowercased().hasPrefix(lowered) }
        let contained = all.filter {
            !$0.key.lowercased().hasPrefix(lowered)
                && ($0.key.lowercased().contains(lowered) || $0.summary.lowercased().contains(lowered))
        }
        return prefixed + contained
    }
}

extension PlistEdit.Kind {
    /// Only offer edits that round-trip exactly through the simple editor.
    static func editable(_ value: Any) -> Bool {
        let kind = of(value)
        let edit = PlistEdit(key: "value", kind: kind, value: text(value))
        guard let roundTrip = edit.object else { return false }
        return NSDictionary(dictionary: ["value": value]).isEqual(to: ["value": roundTrip])
    }

    /// The type a value from a decoded plist should be edited as.
    static func of(_ value: Any) -> PlistEdit.Kind {
        switch value {
        case is Bool:            return .boolean
        case is Int, is Double:  return .integer
        case is [Any]:           return .array
        default:                 return .string
        }
    }

    /// A plist object as the text the editor shows.
    static func text(_ value: Any) -> String {
        switch value {
        case let flag as Bool:   return flag ? "true" : "false"
        case let number as Int:  return String(number)
        case let number as Double: return String(number)
        case let list as [Any]:  return list.map { "\($0)" }.joined(separator: ", ")
        case let text as String: return text
        default:                 return "\(value)"
        }
    }
}
