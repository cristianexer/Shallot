import SwiftUI
import WebKit

/// Hosts a tab's `WKWebView`.
///
/// The web view is built and owned by `BrowserEngine` — fully configured, with
/// its proxy already set — and merely handed here to be displayed. This type
/// deliberately creates nothing: a web view made by the UI layer would be a web
/// view made without a proxy.
public struct WebCanvas: UIViewRepresentable {
    private let webView: WKWebView

    public init(webView: WKWebView) {
        self.webView = webView
    }

    public func makeUIView(context: Context) -> WKWebView {
        webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        // Nothing to push down: the engine drives loading, and the view model
        // drives the engine.
    }
}
