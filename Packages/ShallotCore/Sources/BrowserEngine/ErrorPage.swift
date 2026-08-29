import Foundation

/// The branded page shown when a load is refused or fails.
///
/// A blank white web view after a failed onion lookup reads as "the app is
/// broken". This says what happened and, where it matters, why it was the right
/// thing to do.
public enum ErrorPage {
    public static func html(for reason: NavigationBlockReason, url: URL?) -> String {
        page(title: reason.title, detail: reason.detail, address: url?.absoluteString)
    }

    public static func html(for error: NSError, url: URL?) -> String {
        page(title: title(for: error), detail: detail(for: error, url: url), address: url?.absoluteString)
    }

    static func title(for error: NSError) -> String {
        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Could not find that site"
        case NSURLErrorTimedOut:
            return "The site took too long"
        case NSURLErrorCannotConnectToHost:
            return "Could not connect"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
            return "The secure connection failed"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "The connection dropped"
        default:
            return "The page did not load"
        }
    }

    static func detail(for error: NSError, url: URL?) -> String {
        let host = url?.host() ?? ""
        let isOnion = host.hasSuffix(".onion")
        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost:
            if isOnion {
                return "Tor could not reach this onion service. Onion addresses go offline, and they can change — check the address against a source you trust before assuming it is gone."
            }
            return "Tor reached the network but the site did not answer. It may be down, or the exit relay may be unable to reach it — try a new circuit."
        case NSURLErrorTimedOut:
            return "Tor's three-hop path is slower than a direct connection, but this was slower than that. Try again, or ask for a new circuit from the Monitor."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "This device lost its connection. Nothing was sent outside Tor."
        default:
            return error.localizedDescription
        }
    }

    static func page(title: String, detail: String, address: String?) -> String {
        let escapedTitle = escape(title)
        let escapedDetail = escape(detail)
        let addressBlock = address.map { "<div class=\"addr\">\(escape($0))</div>" } ?? ""
        return """
            <!doctype html>
            <html><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <style>
              :root { color-scheme: dark; }
              html, body { margin: 0; height: 100%; background: #0a0206; }
              body {
                display: flex; align-items: center; justify-content: center;
                padding: 32px;
                font: -apple-system-body;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
                color: #f4e9ec;
              }
              .card { max-width: 30rem; text-align: left; }
              .mark {
                font-family: ui-monospace, "SF Mono", Menlo, monospace;
                font-size: 0.68rem; letter-spacing: 0.22em; text-transform: uppercase;
                color: #ff5069; margin-bottom: 0.75rem;
              }
              h1 { font-size: 1.45rem; line-height: 1.25; margin: 0 0 0.75rem; font-weight: 600; }
              p { font-size: 0.98rem; line-height: 1.6; color: #a3777f; margin: 0; }
              .addr {
                margin-top: 1.25rem; padding: 0.7rem 0.85rem; border-radius: 0.75rem;
                font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.72rem;
                color: #e7c9ce; background: rgba(255, 18, 61, 0.07);
                border: 1px solid rgba(255, 120, 140, 0.3);
                overflow-wrap: anywhere;
              }
            </style>
            </head><body>
              <div class="card">
                <div class="mark">Shallot</div>
                <h1>\(escapedTitle)</h1>
                <p>\(escapedDetail)</p>
                \(addressBlock)
              </div>
            </body></html>
            """
    }

    /// Escapes text going into the page.
    ///
    /// The strings here include hostnames that came from the network, so this
    /// is not cosmetic: an unescaped host is script injection into our own
    /// error page.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
