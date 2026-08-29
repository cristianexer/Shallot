import Foundation

/// Decides what "reload" should actually do.
///
/// `WKWebView.reloadFromOrigin()` only has something to reload once a load has
/// committed. On an error page — a timed-out onion service, a refused
/// connection, a load the kill switch blocked — there is no back-forward item
/// and it silently does nothing. That is precisely the moment someone reaches
/// for reload, so the address the tab was *asked* for is loaded again instead.
///
/// Pure, so the whole matrix is unit-tested rather than discovered by watching
/// a button do nothing.
public enum ReloadPolicy {
    public enum Plan: Equatable, Sendable {
        /// Tor is not carrying traffic; show why rather than trying.
        case refuse(NavigationBlockReason)
        /// A page committed and can be fetched again.
        case reloadFromOrigin
        /// Nothing committed, so ask for the address again.
        case load(URL)
        /// A tab that has never been asked to open anything.
        case nothingToDo
    }

    /// - Parameters:
    ///   - canCarryTraffic: Whether Tor is up. The kill switch comes first.
    ///   - isShowingErrorPage: Whether the web view is displaying one of our
    ///     own error pages rather than a real one.
    ///   - committedURL: `WKWebView.url` — the address that actually loaded.
    ///   - requestedURL: The address the tab was last asked to open.
    public static func plan(
        canCarryTraffic: Bool,
        isShowingErrorPage: Bool,
        committedURL: URL?,
        requestedURL: URL?
    ) -> Plan {
        guard canCarryTraffic else { return .refuse(.torNotRunning) }

        // `about:blank` is where our error pages live, and it is also the state
        // of a web view that has never loaded anything — neither is something
        // `reloadFromOrigin` can act on.
        let hasCommittedPage = !isShowingErrorPage
            && committedURL != nil
            && committedURL?.scheme != "about"

        if hasCommittedPage { return .reloadFromOrigin }
        guard let requestedURL else { return .nothingToDo }
        return .load(requestedURL)
    }
}
