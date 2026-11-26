import UIKit

/// The app's taps, made feelable.
///
/// Kept in one place so the choices stay consistent: a light tap for something
/// that worked, a warning for something that didn't, and nothing at all for
/// background work that the user didn't ask for.
enum Haptics {

    /// A control was used and did what it says.
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Something completed: an install finished, a copy landed.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Something failed, or is about to be destructive.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// A destructive action was confirmed.
    static func destructive() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
}
