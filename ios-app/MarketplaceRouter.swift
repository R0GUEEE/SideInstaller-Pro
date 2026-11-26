import Combine
import Foundation

/// One place for "open the marketplace, searching for this".
///
/// My Apps uses it to send an installed app's bundle ID to the marketplace when
/// there's no newer release in the configured sources: the answer is then a
/// search away rather than a dead end.
final class MarketplaceRouter: ObservableObject {

    static let shared = MarketplaceRouter()

    /// A search to apply next time the marketplace appears. Cleared once used.
    @Published var pendingSearch: String?
    /// Set when the marketplace should show everything, ignoring the last filter.
    @Published var showAllSources = false

    private init() {}

    func search(_ text: String) {
        pendingSearch = text
        showAllSources = true
    }
}

/// Which tab the app is showing, for anything outside the view tree that needs to
/// bring one up — a Shortcuts action, a notification, a deep link.
@MainActor
final class AppRouter: ObservableObject {

    static let shared = AppRouter()

    /// The tab to show. `RootView` observes it and clears it once applied.
    @Published var requestedPage: RootView.Page?

    private init() {}

    func go(_ page: RootView.Page) {
        requestedPage = page
    }
}
