import Domain
import Persistence
import Features
import SwiftUI

/// Shallot — a Tor browser for iPhone and iPad.
///
/// ### The constraint that shapes this whole app
///
/// iOS requires every browser to render with WebKit. Shallot is therefore a
/// `WKWebView` routed through an embedded Tor, not a hardened Firefox fork.
/// Two consequences run through the entire codebase:
///
/// * **Network anonymity is strong**, and it is the core promise: the real IP
///   and location are hidden, destinations are invisible to the local network
///   and the ISP, and `.onion` services are reachable.
/// * **Fingerprinting defence is weaker than desktop Tor Browser and cannot be
///   made equal.** We cannot patch the engine. We mitigate with security levels
///   and by disabling risky features — and we say so plainly in Settings.
@main
struct ShallotApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootShell(model: container.model)
                .task {
                    if let warning = container.storageWarning {
                        container.model.post(warning)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    // Shed background tabs, never Tor: rebuilding a circuit
                    // costs the user far more than reloading a page.
                    Task { await container.model.handleMemoryWarning() }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.willTerminateNotification
                    )
                ) { _ in
                    guard container.settings.settings.clearOnExit else { return }
                    Task { await container.model.clearSession() }
                }
        }
        .commands { ShallotCommands(model: container.model) }
    }
}
