import Domain
import Foundation
import WebKit

/// The WebKit proxy-bypass mitigations. Mandatory, on by default.
///
/// Independent research published in August 2026 documented three WebKit
/// features that reach the network *outside* a configured proxy and therefore
/// leak the device's real IP and DNS — no matter how carefully the proxy is
/// set. They affect every proxy and Tor browser on iOS, and they are not fixed
/// at the OS level, so Shallot mitigates them itself:
///
/// | Bypass | What leaks | Mitigation |
/// |---|---|---|
/// | DNS prefetching (`<link rel="dns-prefetch">`) | Hostname resolved on the device's normal DNS path | `x-dns-prefetch-control: off` plus live stripping of prefetch/preconnect hints |
/// | WebAuthn related-origin requests | Real IP, with no user interaction | `navigator.credentials` and `PublicKeyCredential` removed |
/// | WebTransport | Real IP, direct connection | `WebTransport` removed |
///
/// WebRTC is disabled alongside them — a separate, older leak of the same kind.
///
/// ### Two layers, deliberately
///
/// The script below is the layer we can *guarantee*: it runs at
/// `.atDocumentStart` in every frame, before any page script, so a page can
/// never capture a reference to an API before we remove it. `WebKitFeatureFlags`
/// additionally turns the features off inside the engine where the running
/// WebKit exposes a way to; that layer is best-effort, and this one is not.
public enum LeakMitigations {
    /// Which mitigations to apply. Everything defaults to on.
    public struct Configuration: Sendable, Hashable {
        public var blockDNSPrefetch: Bool
        public var blockWebAuthn: Bool
        public var blockWebTransport: Bool
        public var blockWebRTC: Bool

        public init(
            blockDNSPrefetch: Bool = true,
            blockWebAuthn: Bool = true,
            blockWebTransport: Bool = true,
            blockWebRTC: Bool = true
        ) {
            self.blockDNSPrefetch = blockDNSPrefetch
            self.blockWebAuthn = blockWebAuthn
            self.blockWebTransport = blockWebTransport
            self.blockWebRTC = blockWebRTC
        }

        /// Everything on — the shipping default.
        public static let strict = Configuration()

        /// Derives the configuration for one host from the user's settings,
        /// honouring any per-site opt-in they have deliberately granted.
        public init(settings: AppSettings, host: String?) {
            self.blockDNSPrefetch = settings.blockDNSPrefetch
            self.blockWebAuthn = settings.blockWebAuthn && !settings.allows(.webAuthn, on: host)
            self.blockWebTransport = settings.blockWebTransport && !settings.allows(.webTransport, on: host)
            self.blockWebRTC = settings.blockWebRTC && !settings.allows(.webRTC, on: host)
        }
    }

    /// The name of the message handler pages use to report a blocked attempt.
    public static let messageHandlerName = "shallotLeakReport"

    /// The user scripts to install, in order.
    public static func userScripts(for configuration: Configuration) -> [WKUserScript] {
        [
            WKUserScript(
                source: source(for: configuration),
                injectionTime: .atDocumentStart,
                // Sub-frames are the interesting case: a third-party iframe is
                // exactly where an unwanted prefetch or WebRTC probe shows up.
                forMainFrameOnly: false
            )
        ]
    }

    /// The injected JavaScript. Exposed so its exact contents are unit-tested.
    public static func source(for configuration: Configuration) -> String {
        var body = ""

        if configuration.blockDNSPrefetch {
            body += """
                // ---- DNS prefetching ----------------------------------------
                // Honoured by WebKit since iOS 26, and resolved outside the
                // proxy. The meta tag turns the feature off for the document;
                // the observer removes hints that arrive later, including ones
                // injected by script after the document has parsed.
                var meta = document.createElement('meta');
                meta.setAttribute('http-equiv', 'x-dns-prefetch-control');
                meta.setAttribute('content', 'off');
                var root = document.head || document.documentElement;
                if (root) { root.insertBefore(meta, root.firstChild); }

                var RISKY_RELS = ['dns-prefetch', 'preconnect', 'prefetch', 'prerender'];
                function stripHints(scope) {
                    if (!scope || !scope.querySelectorAll) { return; }
                    var links = scope.querySelectorAll('link[rel]');
                    for (var i = 0; i < links.length; i++) {
                        var rel = (links[i].getAttribute('rel') || '').toLowerCase();
                        if (RISKY_RELS.indexOf(rel) !== -1) {
                            links[i].parentNode && links[i].parentNode.removeChild(links[i]);
                            report('dns-prefetch');
                        }
                    }
                }
                stripHints(document);
                new MutationObserver(function (records) {
                    for (var i = 0; i < records.length; i++) {
                        var added = records[i].addedNodes;
                        for (var j = 0; j < added.length; j++) {
                            var node = added[j];
                            if (node.nodeType !== 1) { continue; }
                            if (node.tagName === 'LINK') {
                                var rel = (node.getAttribute('rel') || '').toLowerCase();
                                if (RISKY_RELS.indexOf(rel) !== -1) {
                                    node.parentNode && node.parentNode.removeChild(node);
                                    report('dns-prefetch');
                                }
                            } else {
                                stripHints(node);
                            }
                        }
                    }
                }).observe(document.documentElement, { childList: true, subtree: true });

                """
        }

        if configuration.blockWebTransport {
            body += """
                // ---- WebTransport -------------------------------------------
                // Opens a direct connection that ignores the proxy entirely.
                remove(window, 'WebTransport');
                remove(window, 'WebTransportDatagramDuplexStream');
                remove(window, 'WebTransportBidirectionalStream');
                remove(window, 'WebTransportError');

                """
        }

        if configuration.blockWebAuthn {
            body += """
                // ---- WebAuthn -----------------------------------------------
                // A related-origin request can be serviced outside the proxy
                // with no user interaction at all, which makes this the worst
                // of the three: a page needs no consent to trigger it.
                remove(navigator, 'credentials');
                remove(window, 'PublicKeyCredential');
                remove(window, 'AuthenticatorAssertionResponse');
                remove(window, 'AuthenticatorAttestationResponse');

                """
        }

        if configuration.blockWebRTC {
            body += """
                // ---- WebRTC -------------------------------------------------
                // The long-standing one: ICE candidate gathering discovers and
                // publishes local and public addresses.
                remove(window, 'RTCPeerConnection');
                remove(window, 'webkitRTCPeerConnection');
                remove(window, 'RTCDataChannel');
                remove(window, 'RTCIceCandidate');
                remove(window, 'RTCSessionDescription');
                if (navigator.mediaDevices) {
                    remove(navigator.mediaDevices, 'getUserMedia');
                    remove(navigator.mediaDevices, 'getDisplayMedia');
                    remove(navigator.mediaDevices, 'enumerateDevices');
                }
                remove(navigator, 'getUserMedia');
                remove(navigator, 'webkitGetUserMedia');

                """
        }

        return """
            (function () {
                'use strict';

                function report(what) {
                    try {
                        window.webkit.messageHandlers.\(messageHandlerName).postMessage(what);
                    } catch (ignored) {}
                }

                // Deleting is not always possible — some of these are
                // non-configurable — so fall back to redefining the property as
                // an undefined getter, which is just as unusable to a page.
                function remove(target, name) {
                    if (!target || !(name in target)) { return; }
                    try {
                        delete target[name];
                        if (!(name in target)) { report(name); return; }
                    } catch (ignored) {}
                    try {
                        Object.defineProperty(target, name, {
                            get: function () { report(name); return undefined; },
                            configurable: false
                        });
                    } catch (ignored) {}
                }

            \(body.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"))
            })();
            """
    }
}
