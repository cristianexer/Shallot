// swift-tools-version: 6.1
//
//  ShallotCore — the layered core of the Shallot Tor browser.
//
//  The app target is deliberately thin: it owns only the entry point, the
//  composition root and the adaptive shell. Everything else lives here so each
//  layer can be built and tested in isolation.
//
//  Dependency direction is strictly downward:
//
//      Features ──▶ DesignSystem ──▶ Domain
//         │                            ▲
//         └──▶ BrowserEngine ──────────┤
//              TorKit ─────────────────┤
//              Persistence ────────────┤
//              Monitoring ─────────────┤
//              AppLock ────────────────┘
//
//  Domain contains models and protocols only. No layer ever imports a concrete
//  implementation of another layer — the app wires them together at launch.
//
import PackageDescription

/// iOS 18 is the floor.
///
/// The build spec asks for iOS 17, but `swift-tor` — the embedded Tor engine —
/// declares `.iOS(.v18)`, and an embedded Tor is non-negotiable for this app.
/// iOS 18 still covers the large majority of active devices.
let iOSFloor = SupportedPlatform.iOS(.v18)

let package = Package(
    name: "ShallotCore",
    platforms: [iOSFloor],
    // Tests live in the app project's `ShallotTests` target rather than here.
    // The WebKit leak tests need a host application to run a real `WKWebView`,
    // and keeping every suite in one target means one command runs all of them
    // — locally and in CI — instead of two that can drift apart.
    products: [
        .library(
            name: "ShallotCore",
            targets: [
                "Domain", "DesignSystem", "TorKit", "BrowserEngine",
                "Persistence", "Monitoring", "AppLock", "Features",
            ]
        )
    ],
    dependencies: [
        // Concurrency-first Swift wrapper around the real Tor C library.
        .package(url: "https://github.com/21-DOT-DEV/swift-tor.git", exact: "0.1.1")
    ],
    targets: [
        // MARK: Domain — models + protocols only.
        .target(name: "Domain"),

        // MARK: DesignSystem — tokens and glass chrome from the approved prototype.
        .target(name: "DesignSystem", dependencies: ["Domain"]),

        // MARK: TorKit — owns the Tor process, control channel and SOCKS ports.
        .target(
            name: "TorKit",
            dependencies: ["Domain", .product(name: "Tor", package: "swift-tor")]
        ),

        // MARK: BrowserEngine — the proxied, hardened WKWebView.
        .target(name: "BrowserEngine", dependencies: ["Domain"]),

        // MARK: Persistence — SwiftData store for favourites and settings.
        .target(name: "Persistence", dependencies: ["Domain"]),

        // MARK: Monitoring — local-only aggregation of Tor and engine events.
        .target(name: "Monitoring", dependencies: ["Domain"]),

        // MARK: AppLock — LocalAuthentication gate and app-switcher shield.
        .target(name: "AppLock", dependencies: ["Domain"]),

        // MARK: Features — one folder per screen, View + @Observable ViewModel.
        .target(
            name: "Features",
            dependencies: ["Domain", "DesignSystem", "BrowserEngine"]
        ),

    ],
    swiftLanguageModes: [.v6]
)
