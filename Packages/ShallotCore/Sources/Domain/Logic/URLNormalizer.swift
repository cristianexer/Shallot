import Foundation

/// Turns whatever the user typed into either a URL to load or a search to run.
///
/// Pure, synchronous and free of side effects so it can be exhaustively tested
/// without a browser, a network, or Tor.
public enum URLNormalizer {
    /// The outcome of interpreting the omnibar's contents.
    public enum Resolution: Sendable, Hashable {
        /// Load this URL directly.
        case url(URL)
        /// Not a URL — search for this text instead.
        case search(String)
        /// Looks like an onion address but is not a valid v3 one. Never loaded.
        case invalidOnion(String)
        /// Nothing usable.
        case empty
    }

    /// Schemes we are willing to hand to the web view.
    ///
    /// Everything else — `file:`, `javascript:`, `data:`, custom app schemes —
    /// is refused. `file:` and `data:` in particular are how a page talks the
    /// browser into loading something outside the proxy.
    public static let allowedSchemes: Set<String> = ["http", "https"]

    /// Interprets `input` as typed into the address bar.
    public static func resolve(_ input: String, httpsOnly: Bool = true) -> Resolution {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // An explicit scheme is honoured if we allow it, and refused if not —
        // we never quietly reinterpret `javascript:` as a search.
        if let schemeRange = trimmed.range(of: "://"),
           case let scheme = String(trimmed[trimmed.startIndex..<schemeRange.lowerBound]).lowercased(),
           !scheme.isEmpty {
            guard allowedSchemes.contains(scheme) else { return .search(trimmed) }
            guard var components = URLComponents(string: trimmed), let host = components.host else {
                return .search(trimmed)
            }
            if OnionAddress.isRejectedOnion(host) { return .invalidOnion(host) }
            // Onion services are their own transport security; upgrading an
            // onion URL to https is pointless and breaks services that only
            // listen on port 80.
            if httpsOnly, scheme == "http", !OnionAddress.isOnion(host) {
                components.scheme = "https"
            }
            guard let url = components.url else { return .search(trimmed) }
            return .url(url)
        }

        // No scheme. Decide whether this smells like a host or like a query.
        guard looksLikeHost(trimmed) else { return .search(trimmed) }

        let hostPart = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let bareHost = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        if OnionAddress.isRejectedOnion(bareHost) { return .invalidOnion(bareHost) }

        // Onion services frequently do not serve TLS, so default them to http.
        let scheme = OnionAddress.isOnion(bareHost) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(trimmed)") else { return .search(trimmed) }
        return .url(url)
    }

    /// Heuristic for "is this a hostname rather than a search query".
    ///
    /// Deliberately conservative: a space anywhere, or no dot at all, means
    /// search. Getting this wrong in the other direction would send a typed
    /// query out as a DNS lookup, which is exactly what we must not do.
    public static func looksLikeHost(_ input: String) -> Bool {
        guard !input.contains(" ") else { return false }
        let hostPart = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        let bareHost = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        guard !bareHost.isEmpty else { return false }
        if bareHost == "localhost" { return true }
        guard bareHost.contains(".") else { return false }
        // A trailing dot-something must look like a TLD, not the end of a
        // sentence: "hello.world" is a host, "what.a day" is not (space caught
        // above), "3.14" is not.
        guard let tld = bareHost.split(separator: ".").last, tld.count >= 2 else { return false }
        return tld.allSatisfy { $0.isLetter }
    }

    /// Whether `url` may be handed to the web view at all.
    public static func isLoadable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            return false
        }
        guard let host = url.host(), !host.isEmpty else { return false }
        return !OnionAddress.isRejectedOnion(host)
    }

    /// The https-upgraded form of `url`, or `nil` if no upgrade applies.
    ///
    /// Onion addresses are never upgraded: the address itself carries the
    /// service's public key, so the connection is already authenticated and
    /// encrypted end to end, and most onion services never obtained a
    /// certificate for port 443.
    public static func httpsUpgrade(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http" else { return nil }
        guard let host = url.host(), !OnionAddress.isOnion(host) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    /// The first-party host used to key circuit isolation and site exceptions.
    public static func registrableHost(for url: URL) -> String? {
        url.host()?.lowercased()
    }
}
