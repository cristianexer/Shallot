import Foundation

/// The open tabs and which one is in front.
///
/// Entirely in-memory by design: a browsing session leaves nothing behind.
@MainActor
public protocol BrowsingSessioning: AnyObject {
    var tabs: [BrowserTab] { get }
    var activeTabID: UUID? { get }
    var activeTab: BrowserTab? { get }

    /// Opens a new tab, optionally at `url`, and makes it active.
    @discardableResult
    func openTab(url: URL?) -> BrowserTab

    /// Closes `id`, activating a neighbour if it was in front.
    func closeTab(_ id: UUID)

    /// Brings `id` to the front.
    func selectTab(_ id: UUID)

    /// Tears down every tab and all of their data stores.
    ///
    /// Called by New Identity; leaves exactly one empty tab behind so the user
    /// lands on the start page rather than on nothing.
    func closeAllTabs()
}
