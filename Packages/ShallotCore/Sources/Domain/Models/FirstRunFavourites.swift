import Foundation

extension Favourite {
    /// The favourites offered on first launch.
    ///
    /// Deliberately all clearnet. Shipping onion addresses would contradict the
    /// warning printed at the top of the Favourites screen: an onion address is
    /// only trustworthy if *you* verified it, and a preloaded one is exactly the
    /// unverified link the app tells you not to trust. A typo-squatted onion
    /// baked into the app would be worse than no default at all.
    ///
    /// The SecureDrop directory is included instead, because it is the
    /// verifiable source a user should get onion addresses from.
    public static let firstRunDefaults: [Favourite] = [
        ("DuckDuckGo", "https://duckduckgo.com"),
        ("Tor Project", "https://www.torproject.org"),
        ("SecureDrop", "https://securedrop.org/directory/"),
        ("ProPublica", "https://www.propublica.org"),
        ("BBC News", "https://www.bbc.co.uk/news"),
        ("Wikipedia", "https://www.wikipedia.org"),
        ("Archive", "https://archive.org"),
    ]
    .enumerated()
    .compactMap { index, entry in
        guard let url = URL(string: entry.1) else { return nil }
        return Favourite(title: entry.0, url: url, sortIndex: index)
    }
}
