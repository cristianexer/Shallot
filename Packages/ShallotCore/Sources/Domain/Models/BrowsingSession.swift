import Foundation
import Observation

/// The concrete, in-memory tab list.
///
/// This lives in `Domain` rather than in a core module because it is pure
/// state with no platform dependency: it knows nothing about WebKit, Tor or
/// storage. The `BrowserViewModel` is what connects a tab to a SOCKS port and
/// to a web view.
@MainActor
@Observable
public final class BrowsingSession: BrowsingSessioning {
    public private(set) var tabs: [BrowserTab] = []
    public private(set) var activeTabID: UUID?

    /// Upper bound on open tabs.
    ///
    /// Bounded because every tab holds a non-persistent data store and a web
    /// view, and because the SOCKS port pool is bounded too.
    public let maximumTabs: Int

    public init(maximumTabs: Int = 12) {
        self.maximumTabs = maximumTabs
    }

    public var activeTab: BrowserTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    @discardableResult
    public func openTab(url: URL? = nil) -> BrowserTab {
        // At the ceiling, recycle the oldest tab that is not in front rather
        // than refusing — silently doing nothing would read as a broken button.
        if tabs.count >= maximumTabs, let oldest = tabs.first(where: { $0.id != activeTabID }) {
            tabs.removeAll { $0.id == oldest.id }
        }
        let tab = BrowserTab(url: url)
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    public func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        guard activeTabID == id else { return }
        // Activate the neighbour to the left, else the new last tab, else none.
        if tabs.isEmpty {
            activeTabID = nil
        } else {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    public func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    public func closeAllTabs() {
        tabs.removeAll()
        activeTabID = nil
    }

    /// Guarantees there is something to show, creating an empty tab if needed.
    @discardableResult
    public func ensureActiveTab() -> BrowserTab {
        if let activeTab { return activeTab }
        if let first = tabs.first {
            activeTabID = first.id
            return first
        }
        return openTab(url: nil)
    }

    public func tab(withID id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }
}
