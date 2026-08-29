# Shallot — Engineering Build Specification (v1.0)

**Deliverable:** a fully working, tested, universal (iPhone + iPad) Tor browser named **Shallot**.
**Audience:** the coding agent implementing it end-to-end in a single build.
**Owner:** Daniel · **Status:** ready to build.

This document is self-contained. Build the whole app in one pass to the Definition of Done in §16. Where an API is version-sensitive, the spec says so and tells you what to confirm against the installed SDK — do that rather than guessing.

---

## 1. Read this first — the constraint that shapes the whole app

iOS forbids third-party browser engines. Every browser on iPhone/iPad must render with Apple's **WebKit** (`WKWebView`). The EU's DMA created a narrow alternative-engine exception; it does **not** apply in the UK or most of the world. So Shallot is **`WKWebView` routed through Tor**, not a hardened Firefox fork like desktop Tor Browser.

Two consequences that are non-negotiable in the design:

1. **Network-layer anonymity is strong and is our core promise.** Tor hides the real IP and location, defeats local/ISP surveillance of destinations, and reaches `.onion` services.
2. **Browser-fingerprint defence is weaker than desktop Tor Browser and cannot be made equal.** We cannot patch the engine, so JavaScript fingerprinting surfaces (canvas, WebGL, screen, fonts) still largely reflect the device. We mitigate with a security-level control and by disabling risky features, and we **tell the user the truth in-app** (§8, §7.4). Overstating protection to a journalist or activist is the one mistake this app must never make.

There is a second, newer hazard that is equally load-bearing: **WebKit has known proxy bypasses that leak the real IP/DNS even when a proxy is set.** These are unpatched at the OS level as of this writing (Apple fix targeted for late 2026). Shallot **must** implement its own mitigations — see §9, which is mandatory, not optional.

---

## 2. Scope of this build

**In scope (single phase, ship-quality):**
- Universal SwiftUI app, iPhone + iPad, adaptive layout.
- Embedded Tor with in-app SOCKS5 routing of `WKWebView`.
- Browser: tabs, address/search, `.onion`, HTTPS-only, New Identity, per-tab circuit isolation, security levels.
- Favourites (local, encrypted).
- Settings (security level, bridges/transports, privacy toggles, app lock).
- Monitoring (live circuit view, bandwidth, event log).
- WebKit leak mitigations (DNS-prefetch, WebAuthn, WebTransport, WebRTC).
- App lock (Face ID / Touch ID / passcode) + app-switcher privacy.
- Full automated test suite (§15) and CI.

**Out of scope (explicitly, to prevent scope creep):**
- System-wide VPN tunnelling of *all* apps via `NEPacketTunnelProvider` (a future option; needs the Network Extension entitlement).
- Cloud sync of anything.
- macOS / Android / watchOS.
- Fingerprint parity with desktop Tor Browser (impossible on WebKit).

---

## 3. Platform, tooling, dependencies

- **Xcode 26+**, **Swift 6** (strict concurrency on).
- **Minimum deployment target: iOS 17.0 / iPadOS 17.0.** This is required: `WKWebsiteDataStore.proxyConfigurations` (our routing mechanism), SwiftData, and the `@Observable` macro all require iOS 17. This floor covers the large majority of active devices.
- **Universal** target (iPhone + iPad), portrait + landscape; iPad supports Split View / Stage Manager.
- **UI:** SwiftUI first, with `UIViewRepresentable` bridges where UIKit is required (`WKWebView` has no SwiftUI equivalent, so it is always bridged).
- **Concurrency:** Swift Concurrency throughout. The Tor engine is an `actor`; UI types are `@MainActor`.
- **Liquid Glass:** adopt the native iOS 26 `glassEffect` APIs where available, with a material fallback below (§7.3). Availability-gate all iOS 26 calls.

**Dependencies (Swift Package Manager):**

| Purpose | Primary choice | Notes |
|---|---|---|
| Embedded Tor | **`swift-tor`** (21-DOT-DEV) — concurrency-first Swift wrapper; SOCKS5 proxy, control protocol, `makeURLSession()`, onion services | Modern async API, Swift 6 compliant. |
| Embedded Tor (fallback) | **`Tor.framework`** (iCepa) — the battle-tested lib used by Onion Browser and Orbot | Objective-C, callback style; use if `swift-tor` gaps appear. |
| Pluggable transports | **IPtProxy** — obfs4 + Snowflake bridges | Needed for censored networks (§6.1.4). |
| Snapshot tests | `pointfreeco/swift-snapshot-testing` | §15.4. |
| Lint / format | SwiftLint, swift-format | CI gates. |

Wrap Tor behind **our own protocol** (`TorServicing`, §6.1) so the concrete library is swappable and the exact method names of whichever lib you pick are confined to one adapter. **Confirm the adapter's calls against the installed package version** — Tor wrapper APIs move.

> **Entitlements:** the in-app proxy route needs **no special entitlement** — `proxyConfigurations` is public API. Only the out-of-scope system tunnel would need Network Extension. The only Info.plist addition required is `NSFaceIDUsageDescription`. Declare `ITSAppUsesNonExemptEncryption` appropriately for App Store export compliance (Tor uses encryption; Tor apps do ship, so this is routine).

---

## 4. Architecture

Layered, modular, dependency-inverted. UI depends on protocols; concrete services are injected. The Tor engine is isolated behind an actor and a protocol so nothing in the UI ever touches the raw library.

```
┌───────────────────────────────────────────────────────────┐
│  App layer      ShallotApp (entry, DI container, routing)  │
├───────────────────────────────────────────────────────────┤
│  Features       Browser · Favourites · Monitor · Settings   │
│  (SwiftUI +     each = View + @Observable ViewModel          │
│   Observation)  depends only on protocols below              │
├───────────────────────────────────────────────────────────┤
│  Domain         Models + service protocols                   │
│                 TorServicing · BrowsingSession · FavouritesRepo│
│                 SettingsStore · MonitorFeed · AppLocking      │
├───────────────────────────────────────────────────────────┤
│  Core impl      TorKit · BrowserEngine · Persistence         │
│                 Monitoring · AppLock · DesignSystem           │
├───────────────────────────────────────────────────────────┤
│  Platform       WebKit · Network.framework · LocalAuth ·     │
│                 SwiftData · swift-tor / IPtProxy              │
└───────────────────────────────────────────────────────────┘
```

**Pattern:** MVVM using the Observation framework (`@Observable` view models, iOS 17+). No third-party architecture framework.

**Dependency injection:** a single `AppContainer` built at launch, holding live service instances, passed into the root via the SwiftUI `Environment`. Feature view models receive their dependencies through their initialisers. Provide `Preview`/`Mock` implementations of every protocol so views, previews, and tests never spin up real Tor.

**Data-flow rule (the wiring):** UI → ViewModel → Domain protocol → Core impl. State flows back via `@Observable` properties and `AsyncStream`s (bootstrap %, bandwidth, circuit changes, security events). No view talks to WebKit, Tor, or storage directly.

---

## 5. Project structure

Use **local Swift packages** for the core modules so the app stays scalable and each module is independently testable. The app target is thin.

```
Shallot/
├─ Shallot.xcodeproj  (or App.xcworkspace)
├─ App/
│  ├─ ShallotApp.swift            // @main, scene, DI wiring
│  ├─ AppContainer.swift          // composition root
│  ├─ RootView.swift              // size-class adaptive shell (§7.2)
│  └─ Info.plist                  // NSFaceIDUsageDescription, ATS, encryption
├─ Packages/
│  ├─ Domain/                     // models + protocols ONLY (no impl, no UIKit)
│  │  └─ Sources/Domain/
│  │     ├─ Models/ (Tab, Favourite, Circuit, RelayNode, SecurityLevel,
│  │     │          BridgeConfig, SecurityEvent, AppSettings)
│  │     └─ Protocols/ (TorServicing, BrowsingSessioning, FavouritesRepository,
│  │                    SettingsStoring, MonitorFeeding, AppLocking)
│  ├─ TorKit/                     // Tor engine actor + control + transports
│  │  └─ Sources/TorKit/ (TorService, TorControlAdapter, BridgeManager,
│  │                      SocksPortPool, TorState)
│  ├─ BrowserEngine/              // WKWebView wrapper + proxy + hardening
│  │  └─ Sources/BrowserEngine/ (WebView, WebViewCoordinator, ProxyConfigurator,
│  │                             LeakMitigations, SecurityPolicy, ContentBlocker,
│  │                             NavigationPolicy)
│  ├─ Persistence/               // SwiftData store + repositories
│  │  └─ Sources/Persistence/ (FavouriteModel, SettingsModel, FavouritesRepo,
│  │                           SettingsStore, ModelContainer+Shallot)
│  ├─ Monitoring/                // aggregates Tor + engine events
│  │  └─ Sources/Monitoring/ (MonitorService, BandwidthSampler, EventLog)
│  ├─ AppLock/                   // LocalAuthentication + privacy overlay
│  │  └─ Sources/AppLock/ (AppLockService, PrivacyShield)
│  ├─ DesignSystem/             // tokens + glass components (matches prototype)
│  │  └─ Sources/DesignSystem/ (Tokens, GlassPanel, GlassBar, RainView,
│  │                           Typography, SecuritySlider, Toast)
│  └─ Features/                 // one folder per screen
│     └─ Sources/Features/
│        ├─ Browser/ (BrowserView, BrowserViewModel, OmniBar, StartPage, TabBar)
│        ├─ Favourites/ (FavouritesView, FavouritesViewModel, FavouriteCard)
│        ├─ Monitor/ (MonitorView, MonitorViewModel, CircuitChain, Sparkline)
│        └─ Settings/ (SettingsView, SettingsViewModel, LevelPicker)
├─ Resources/
│  └─ Tor/ (geoip, geoip6)        // bundled GeoIP files for circuit country labels
└─ Tests/
   ├─ UnitTests/                  // Swift Testing
   ├─ IntegrationTests/           // real Tor, device lane
   ├─ SecurityLeakTests/          // the crown jewels (§15.5)
   ├─ UITests/                    // XCUITest
   ├─ SnapshotTests/
   └─ PerformanceTests/
```

Every package has its own `Tests/` for unit coverage; cross-cutting suites live in top-level `Tests/`.

---

## 6. Core subsystems

### 6.1 TorKit — the Tor engine

`TorService` is an `actor` conforming to `Domain.TorServicing`. It owns Tor's lifecycle and the control channel; it never touches UI.

**Responsibilities**
1. Start Tor with a non-persistent data directory and a **known SOCKS port** (needed to point the proxy at it). Bundle and pass `geoip`/`geoip6`.
2. Publish **bootstrap progress** (0–100) and a **bootstrapped/circuit-established** flag as an `AsyncStream`.
3. **New Identity** → send `SIGNAL NEWNYM` on the control port (do **not** stop/restart the process — see caveat).
4. Provide **circuit status** and **bandwidth** by polling `GETINFO circuit-status` / traffic counters (or subscribing to control events) for the Monitor.
5. Configure **pluggable transports** (obfs4, Snowflake) via IPtProxy + Tor `ClientTransportPlugin` when bridges are enabled.
6. Vend **per-isolation SOCKS ports** (see §6.2).

```swift
public protocol TorServicing: Sendable {
    var state: TorState { get async }                       // .off/.starting(Int)/.running/.failed
    func start() async throws
    func bootstrapProgress() -> AsyncStream<Int>            // 0...100
    func newIdentity() async throws                         // SIGNAL NEWNYM
    func circuits() async throws -> [Circuit]               // GETINFO circuit-status
    func bandwidth() -> AsyncStream<BandwidthSample>        // read/written deltas
    func socksPort(forIsolationKey key: IsolationKey) async throws -> UInt16
    func setBridges(_ config: BridgeConfig?) async throws   // requires restart of Tor config
}
```

**Adapter (swift-tor), sketch — confirm names against the installed version:**
```swift
import Tor  // swift-tor

actor TorService: TorServicing {
    private var client: TorClient?
    private var control: TorControlClient?

    func start() async throws {
        let config = TorConfiguration(
            dataDirectory: Self.ephemeralDir(),           // wiped on exit
            cacheDirectory: Self.cacheDir(),
            socksPort: .port(39050)                        // fixed, or .ephemeral then read back
        )
        let client = TorClient(configuration: config)
        try await client.start()
        try await client.waitUntilBootstrapped()
        self.client = client
        self.control = try await client.controlClient()   // GETINFO / SIGNAL / ADD_ONION
    }

    func newIdentity() async throws {
        try await control?.signal(.newnym)                 // verify: .signal / send("SIGNAL NEWNYM")
    }

    func circuits() async throws -> [Circuit] {
        let raw = try await control?.getInfo("circuit-status") ?? ""
        return CircuitStatusParser.parse(raw)              // our parser, unit-tested
    }
}
```
*Fallback (iCepa `Tor.framework`): `TORConfiguration` + `TORThread` + `TORController.authenticate(withData:)`, then `addObserver(forCircuitEstablished:)`, `getInfoForKeys(["circuit-status"])`, and a `sendCommand`/signal for NEWNYM. `getSessionConfiguration` yields a Tor-routed `URLSessionConfiguration` (handy for §15.5).*

> **Hard caveat — Tor global state.** The embedded Tor C library keeps process-global state and **cannot be restarted within the same process** after it stops. Therefore: start Tor once per launch; use `NEWNYM` for new identity; and to apply a **bridge change** (which needs new Tor config), the correct behaviour is to inform the user a relaunch is required, or gate bridge config so it's set before Tor starts. Do **not** attempt stop→start mid-session.

### 6.2 Per-tab circuit isolation (do it the reliable way)

Desktop Tor Browser isolates circuits per first-party domain using SOCKS username/password (`IsolateSOCKSAuth`). **That path is currently broken on `WKWebView`:** setting SOCKS credentials via `ProxyConfiguration.applyCredential(username:password:)` does not authenticate reliably in WebKit (an Apple-acknowledged bug). **Do not rely on SOCKS-auth isolation.**

Use this instead:
- **Primary — per-tab SOCKS ports.** `SocksPortPool` in TorKit opens a small pool of Tor `SOCKSPort` lines. Each open tab is assigned a port from the pool; its `WKWebsiteDataStore` proxy points at that port, so Tor gives that tab its own circuit. Ports are recycled when tabs close. Bound the pool (e.g. 6–8) and share beyond that.
- **Complement — destination isolation flags.** Configure each `SOCKSPort` with `IsolateDestAddr IsolateDestPort` so even within a tab, distinct destinations get distinct circuits automatically, no SOCKS auth needed.

Document this choice in code comments; it's a correctness decision, not an accident.

### 6.3 BrowserEngine — the hardened web view

`WebView: UIViewRepresentable` builds and wires the `WKWebView`. Central rules:

- **Data store:** `WKWebsiteDataStore.nonPersistent()` per tab (ephemeral — no history/cookies to disk).
- **Proxy:** on iOS 17+, set
  ```swift
  let endpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                     port: NWEndpoint.Port(rawValue: torSocksPort)!)
  let proxy = ProxyConfiguration(socksv5Proxy: endpoint)   // SOCKS5, NOT httpCONNECT
  dataStore.proxyConfigurations = [proxy]
  ```
  **Set the proxy before the first `load(...)`** (changing it mid-load interrupts networking, and there is a reported crash on iOS 18 when mutating `proxyConfigurations` on a live web view — build the store fully configured, then create the web view). Use **SOCKS5, not HTTP CONNECT** (HTTP CONNECT proxying has WebKit bugs; Apple's own guidance is to prefer SOCKS5).
- **Kill-switch:** the engine refuses to `load` anything unless `TorService.state == .running`. If Tor drops, block navigation and surface the connecting state. This prevents clearnet leaks — it is a security control, not UX polish.
- **DNS through Tor:** SOCKS5 hands hostnames (incl. `.onion`) to Tor for remote resolution. Never resolve locally. (But see §9 — WebKit can still bypass this for specific features; mitigations required.)
- **Navigation delegate / `NavigationPolicy`:** HTTPS-only (upgrade `http`→`https`; block if it fails), mixed-content blocking, TLS state for the omnibar, error pages for failed onion/timeout loads.
- **Security level** applied per navigation via `WKWebpagePreferences` (§6.5).
- **Content blocking:** compile a `WKContentRuleList` to block third-party trackers and enforce `upgrade-insecure-requests`; feed blocked events to the Monitor.

### 6.4 Tabs & session

`BrowsingSession` (Domain) manages an ordered list of `Tab` (id, title, url, isolation port, loading state, security level). Everything is in-memory; nothing persists. New Identity closes all tabs, clears all data stores, and calls `TorService.newIdentity()`.

### 6.5 Security levels

`SecurityLevel` = `.standard | .safer | .safest`, mapped to WebKit config:

| Level | JavaScript | Extra |
|---|---|---|
| Standard | on | all features (still with §9 leak mitigations always on) |
| Safer | on | block risky content via rule list; stricter content blocking |
| Safest | **off** (`WKWebpagePreferences.allowsContentJavaScript = false`) | maximum protection; some sites break — that's expected and communicated |

`allowsContentJavaScript` is public and applied in `webView(_:decidePolicyFor:preferences:)`. JS-off is our strongest realistic fingerprinting lever on WebKit.

### 6.6 Favourites

`FavouritesRepository` over SwiftData. `FavouriteModel` = id, title, url, isOnion, sortIndex, dateAdded. Stored **on-device only, encrypted at rest** via `FileProtection.complete` on the store; **no cloud sync** (sync is a deanonymisation surface). Optional encrypted export/import. UI shows a persistent "verify before trusting — onion addresses can change" note.

### 6.7 Settings

`SettingsStore` over SwiftData (`SettingsModel`, one row). Non-sensitive prefs; nothing security-critical stored in plaintext. Controls: security level; bridges on/off + transport (obfs4/Snowflake) + custom bridge lines; default search engine (DuckDuckGo onion); HTTPS-only; block WebRTC; per-tab isolation; clear-on-exit; Face ID lock; hide-in-app-switcher; the per-site opt-ins for the §9-disabled features; About with the honesty statement.

### 6.8 Monitoring

`MonitorService` (Domain `MonitorFeeding`) aggregates: circuit chain (from `TorService.circuits()` — relay nickname, country from GeoIP, latency), bootstrap %, bandwidth stream, and a `SecurityEvent` log fed by the engine (DNS-via-Tor confirmations, WebRTC/tracker/mixed-content blocks, circuit rebuilds). **All computed locally; no external calls, no telemetry.**

### 6.9 App lock

`AppLockService` uses **LocalAuthentication** (`LAContext`, Face ID / Touch ID / device passcode fallback) to gate app entry when enabled. `PrivacyShield` overlays a blur/placeholder when `scenePhase` becomes `.inactive`/`.background` so the app-switcher snapshot never shows content. Both toggle from Settings.

---

## 7. UI / UX

### 7.1 Design language (match the approved prototype)

Reuse the tokens from the signed-off prototype (`shallot-ui.html`): **Matrix-style blood-red digital rain behind translucent Liquid Glass chrome.**

- **Palette:** void `#0a0206`, deep blood `#8b0000`, arterial `#ff123d`, rain `#ff2b45`, bone `#f4e9ec`, ash `#a3777f`.
- **Type:** **SF Mono** for chrome/labels/data (terminal feel), **SF Pro** for readable body — the native iOS pairing.
- **Signature:** red digital-rain canvas refracting *through* the glass bars. Keep boldness here; everything else quiet.
- **Screens:** Browser (start page + omnibar + tab bar; loads real pages with a progress bar), Favourites, Monitor, Settings — exactly as prototyped, including the slim single-row omnibar (back, forward, address pill, reload, **mask** = New Identity) and the icon-only tab bar.

### 7.2 Adaptive layout — iPhone and iPad both first-class

Drive layout off `horizontalSizeClass`:

- **Compact (iPhone portrait):** the prototype layout — floating glass **bottom tab bar**, sticky glass omnibar, content scrolls beneath (glass refraction on scroll).
- **Regular (iPad, iPhone landscape/large):** `NavigationSplitView` — a **sidebar** (Browser / Favourites / Monitor / Settings + open-tabs list) and a **detail** pane with the web canvas and omnibar. The bottom tab bar collapses into the sidebar. Larger type scale, more generous spacing.
- iPad extras: **keyboard shortcuts** (`⌘L` focus address, `⌘T` new tab, `⌘W` close tab, `⌘R` reload, `⌘⇧N` New Identity, `⌘F` find), pointer/hover states, and (optional) multiple-window support via scene sessions. Verify under **Stage Manager** and Split View.

`RootView` picks the shell; both shells bind to the **same** view models, so behaviour is identical and only the chrome differs.

### 7.3 Liquid Glass adoption (iOS 26+) with fallback

- On **iOS 26+**, use `.glassEffect(_:in:)` (variants `.regular`/`.clear`, `.tint()`, `.interactive()`) for the omnibar, tab bar, cards, and sheets, grouped in a `GlassEffectContainer` where multiple glass elements sit together (glass can't sample glass — never nest; group instead). Keep glass in the **navigation/control layer only, never on content** (HIG rule).
- On **iOS 17–25**, fall back to `.ultraThinMaterial` + the prototype's border/blur treatment. One `GlassPanel`/`GlassBar` component in DesignSystem encapsulates the `if #available(iOS 26, *)` split so features never branch on OS version.
- Known gotcha to pre-empt: if a toolbar goes opaque with `.toolbarColorScheme`, apply `.toolbarBackground(.ultraThinMaterial, for: .navigationBar)`.

### 7.4 Accessibility & quality floor

- **Dynamic Type** everywhere (no fixed font sizes on text that carries meaning); layouts reflow.
- **VoiceOver** labels on every control (the tab bar is icon-only — labels are mandatory; already stubbed with `aria`-equivalent `accessibilityLabel`).
- **Reduced Motion:** freeze the digital rain and disable non-essential animation when `accessibilityReduceMotion` is set.
- **Contrast:** body/labels stay light on dark; reserve red for accents/large text (small red-on-black fails contrast).
- **Tap targets ≥ 44×44 pt.** Visible keyboard focus. Support landscape and both platforms.
- **In-app honesty banner** in Settings/About: Shallot hides IP and location and reaches `.onion`, but because iOS requires WebKit it can't fully match desktop Tor Browser's anti-fingerprinting — raise the security level for more protection.

---

## 8. Privacy & security requirements (summary of guarantees)

1. All web traffic routed through Tor; **kill-switch** blocks loads when Tor isn't running.
2. **Ephemeral by default** — no history/cookies/cache to disk; cleared on New Identity and (optionally) on exit.
3. **Per-tab circuit isolation** (§6.2), plus destination isolation flags.
4. **DNS through Tor**; WebKit-bypass mitigations enforced (§9).
5. **Security levels** incl. JS-off on Safest.
6. **No telemetry, analytics, or crash reporting that could leak URLs/PII.** Any diagnostics are opt-in and stripped. Verified by test (§15.5).
7. **HTTPS-only** + mixed-content blocking.
8. **App lock** + app-switcher privacy shield.
9. **Honest in-app comms** about the fingerprinting ceiling.

---

## 9. WebKit proxy-bypass mitigations (MANDATORY)

Independent research (Mysk / Bakry, Aug 2026) documented **three WebKit features that bypass a configured proxy and leak the device's real IP/DNS**, affecting every iOS proxy/Tor browser (Onion Browser included), regardless of how carefully the proxy is set. They are **not fixed at the OS level** as of this writing (Apple fix targeted late 2026), so Shallot must mitigate them itself — mirroring what Psylo shipped.

| Bypass | What leaks | Required mitigation (default ON) |
|---|---|---|
| **DNS prefetching** (`<link rel="dns-prefetch">`, honoured since iOS 26) | Hostname resolved via the device's normal DNS path, outside the proxy | Inject `<meta http-equiv="x-dns-prefetch-control" content="off">` at document start; strip `<link rel="dns-prefetch">` and `rel="preconnect">` via user script |
| **WebAuthn Related Origin Requests** (passkeys) | Real IP, no user interaction | **Disable WebAuthn** by default via WebKit configuration/feature flags |
| **WebTransport** | Real IP, direct connection | **Disable WebTransport** by default via WebKit feature flags |

Implementation notes:
- Put all of this in `BrowserEngine/LeakMitigations`. DNS-prefetch off is a `WKUserScript` at `.atDocumentStart` for all frames.
- WebAuthn/WebTransport are disabled through WebKit feature configuration (follow Psylo's approach; the exact preference/feature keys are WebKit-internal and version-sensitive — **confirm the current keys** and centralise them in one place).
- Provide **per-site opt-in** re-enablement in Settings for sites that genuinely need these, off by default — the privacy trade-off stays in the user's hands.
- **Also disable WebRTC** (separate long-standing IP-leak vector) by default.
- Treat this table as a living checklist: when Apple ships the OS fix, keep the mitigations and re-verify.

This section is a correctness requirement. The leak tests in §15.5 exist specifically to prove these mitigations work.

---

## 10. Data & persistence

- **Persisted:** Favourites and Settings only, via SwiftData with `FileProtection.complete`. No browsing history is ever written.
- **Never persisted:** cookies, cache, page data, tabs, monitor logs (all ephemeral, in-memory).
- **Secrets:** if any credential/token is ever stored, use the **Keychain** (with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), never SwiftData/UserDefaults.
- **No analytics SDKs.** No network egress except Tor's own and loopback.

---

## 11. Concurrency & performance

- **Actors** for TorKit and any shared mutable state; `@MainActor` for view models/UI; pass `Sendable` values across boundaries. Compile clean under Swift 6 strict concurrency.
- **Keep Tor warm** for the whole session; **pre-build circuits** where the lib allows so the first navigation is fast. Cache the Tor consensus (`cacheDirectory`) for faster warm starts.
- **Latency honesty:** Tor's three-hop path has a fixed latency floor; "fast" means minimising Shallot's own overhead, never reducing hops or weakening isolation for speed.
- **Targets (tune on device):** cold start to interactive quickly; visible bootstrap progress; 60 fps scrolling on iPhone and **120 fps (ProMotion) on iPad Pro**; bounded memory with the rain canvas (throttle when backgrounded / Reduce Motion).

---

## 12. Error handling & edge cases (handle all)

Tor bootstrap failure/timeout (retry + clear message); network change / airplane mode mid-session; bridge connection failure (fall back / guide the user); page load errors over Tor and `.onion` resolution failures (branded error state, not a blank page); load attempted before bootstrap (kill-switch blocks, shows connecting); backgrounding during load; low-memory (shed tabs, keep Tor); rapid tab open/close (port pool must not leak ports); malformed URLs and bad bridge lines (validated, never crash); JS-off breaking a site (offer to raise level for that site).

---

## 13. Wiring & connection map (so nothing is left unconnected)

- `ShallotApp` builds `AppContainer` → constructs `TorService`, `BrowsingSession`, `FavouritesRepository`, `SettingsStore`, `MonitorService`, `AppLockService` → injects into `RootView` via Environment.
- On launch: `AppLockService` gates entry (if enabled) → `TorService.start()` runs, `RootView` shows bootstrap progress from `bootstrapProgress()`.
- `BrowserViewModel` owns tabs via `BrowsingSession`, asks `TorService.socksPort(forIsolationKey:)` per tab, hands it to `BrowserEngine` which builds the proxied web view; navigation/security events flow to `MonitorService`.
- `FavouritesViewModel` ↔ `FavouritesRepository`; tapping a favourite drives `BrowserViewModel.open(url:)`.
- `MonitorViewModel` subscribes to `MonitorFeeding` streams (circuit/bandwidth/events); "New Circuit"/"New Identity" call `TorService`.
- `SettingsViewModel` ↔ `SettingsStore`; changing security level/bridges/toggles propagates to `BrowserEngine`/`TorService` (bridges → relaunch-required flow per §6.1 caveat).

---

## 14. Build & run

1. Xcode 26+, open the workspace, resolve SPM packages.
2. Add `Resources/Tor/geoip` + `geoip6` to the app bundle; pass their paths to Tor config.
3. Info.plist: `NSFaceIDUsageDescription`; ATS defaults (do not globally disable ATS); set `ITSAppUsesNonExemptEncryption` for export compliance.
4. No special entitlements for the in-app proxy route.
5. Signing: standard automatic signing; universal (iPhone + iPad) run destinations.
6. Run on **device** for anything touching Tor/networking (the Simulator uses the macOS networking stack and can mislead — Apple's own DTS advises testing proxy/TLS on real hardware).

---

## 15. Testing strategy (comprehensive — implement all)

Use **Swift Testing** for unit/logic and **XCUITest** for UI. Every core package ships its own unit tests. Split suites so device-only tests (real Tor) run in a dedicated lane.

### 15.1 Unit tests
Models and pure logic: URL/`.onion` parsing and validation; `SecurityLevel` → WebKit-config mapping; `CircuitStatusParser` (feed captured `GETINFO circuit-status` fixtures → expected `[Circuit]`); `BandwidthSampler` deltas; `FavouritesRepository` CRUD + sort/dedup; `SettingsStore` round-trips; bridge-line parsing; `SocksPortPool` acquire/recycle (no leaks, bounded); `LeakMitigations` user-script generation (asserts the exact dns-prefetch meta + strip script); `NavigationPolicy` http→https upgrade decisions. Use **mock `TorServicing`** — no real Tor in unit tests.

### 15.2 Integration tests (device lane, needs network)
Tor actually bootstraps within timeout; **routing verification** — fetch `https://check.torproject.org/api/ip` through the app's Tor-routed session and assert `IsTor == true` and IP ≠ the device's real IP; `.onion` reachability (load a known onion, assert success); **per-tab isolation** — two tabs report different exit IPs; content blocking active (a tracker request is blocked); Safest actually disables JS (a JS probe fails to run).

### 15.3 UI tests (XCUITest)
Tab navigation across all four screens; load a page + scroll the long article + confirm chrome stays pinned; New Identity returns to start page and clears; Settings toggles flip and persist; Favourites add/rename/reorder/delete; iPad `NavigationSplitView` sidebar + detail; iPad keyboard shortcuts; app-lock prompt appears when enabled.

### 15.4 Snapshot tests (`swift-snapshot-testing`)
DesignSystem components + every screen across **iPhone SE, iPhone Pro Max, iPad Pro**, light/dark, several **Dynamic Type** sizes, and Reduce-Motion on. Catches layout/contrast regressions.

### 15.5 Security & leak tests (the crown jewels — must pass to ship)
- **DNS-prefetch leak:** load a page containing `<link rel="dns-prefetch">`; assert no DNS query originates off-proxy. Use the public PoC (`leaks.psylo.app`) and/or a controlled authoritative DNS to confirm the real network never appears.
- **WebAuthn / WebTransport:** feature-detect in-page; assert both are **unavailable** (disabled).
- **WebRTC:** run an RTC probe; assert **no host/srflx candidates** expose the real IP.
- **IP check:** `check.torproject.org/api/ip` → `IsTor == true`, IP ≠ real.
- **Kill-switch:** with Tor forced down, attempt navigation; assert **no request leaves the device** and load is blocked.
- **No telemetry:** monitor egress across a full session; assert only Tor/loopback endpoints are contacted. Fail the build on any non-Tor host.

### 15.6 Performance tests
`XCTClockMetric`/`XCTOSSignpostMetric`/`XCTMemoryMetric` for: cold start, Tor bootstrap time, first page-load-over-Tor, scroll hitch rate, and memory footprint (incl. the rain canvas). Set budgets and fail on regression.

### 15.7 Accessibility tests
`try await app.performAccessibilityAudit()` (XCUITest, iOS 17+) on each screen; assert VoiceOver labels present on all controls; verify Dynamic Type reflow at accessibility sizes.

### 15.8 Robustness / fuzz
Malformed URLs, enormous pages, rapid tab churn, malformed bridge lines, backgrounding mid-load, repeated New Identity — none may crash or leak ports/memory.

### 15.9 Manual QA matrix (pre-release)
Devices: iPhone SE (small), iPhone Pro Max, iPad mini, iPad Pro. Orientations both. A **real censored-network test** with obfs4/Snowflake bridges. Real onion sites. A full VoiceOver pass.

### 15.10 CI
Xcode Cloud (or GitHub Actions with `xcodebuild`): on every PR run build + unit + UI + snapshot tests, SwiftLint, swift-format. Run integration/leak/performance tests in a **device lane / nightly** (they need real network + hardware). Block merge on red.

---

## 16. Definition of Done (acceptance criteria)

The app is done when **all** of the following hold:

- [ ] Universal build runs on iPhone and iPad; adaptive layout verified on both (compact + `NavigationSplitView`), portrait + landscape, Stage Manager/Split View on iPad.
- [ ] All four screens are fully wired to live services (§13) — no dead buttons, no placeholder data.
- [ ] Tor bootstraps with visible progress; **routing verified** (`IsTor == true`, IP ≠ real).
- [ ] Kill-switch blocks all loads when Tor isn't running (proven by test).
- [ ] Per-tab circuit isolation works (two tabs → two exit IPs).
- [ ] Security levels apply; Safest disables JS.
- [ ] **All §9 leak mitigations active and proven** by §15.5 (DNS-prefetch, WebAuthn, WebTransport, WebRTC), with per-site opt-in.
- [ ] Pages open like real webpages (progress bar + scroll); glass chrome refracts scrolling content.
- [ ] Favourites persist **encrypted** on-device (no cloud); Settings persist and take effect.
- [ ] Monitor shows live circuit, bandwidth, and event log — all local, zero telemetry (proven by egress test).
- [ ] App lock (Face ID/Touch ID/passcode) + app-switcher privacy shield work.
- [ ] In-app honesty statement about the fingerprinting ceiling is present.
- [ ] **All test suites green** (unit, integration, UI, snapshot, leak, performance, accessibility); CI passing; SwiftLint/format clean; Swift 6 strict-concurrency clean.
- [ ] Accessibility audit passes; Dynamic Type, VoiceOver, Reduce Motion all supported.

---

## 17. Risks & explicit verification points

- **WebKit proxy bypasses (§9)** — highest technical risk. Mitigate now; monitor Apple's fix; keep leak tests permanently.
- **SOCKS-auth isolation is broken on WebKit** — hence the per-tab-ports design (§6.2). Don't regress to SOCKS credentials.
- **`proxyConfigurations` mutation crash on iOS 18** — configure the store fully before creating the web view; never mutate on a live view.
- **Tor global state / no restart** — one start per launch; NEWNYM for identity; relaunch flow for bridge changes.
- **Fingerprinting ceiling** — communication risk (users over-trusting). Mitigated by the honesty banner + security levels.
- **Library API drift** — confine Tor calls to one adapter; confirm method names against the installed `swift-tor`/`Tor.framework` version.
- **App Store review** — Tor apps are permitted (Onion Browser, Orbot ship); handle encryption export compliance.

---

## 18. Sources / further reading

- WebKit `WKWebsiteDataStore.proxyConfigurations` — Apple docs; WebKit headers (iOS 17/macOS 14). https://developer.apple.com/documentation/webkit/wkwebsitedatastore/4264546-proxyconfigurations
- `ProxyConfiguration` / `init(socksv5Proxy:)` / `applyCredential(username:password:)` — Apple docs. https://developer.apple.com/documentation/network/proxyconfiguration
- WebKit proxy bypass research (DNS prefetching, WebAuthn, WebTransport) — Mysk. https://mysk.blog/2026/08/04/webkit-proxy-icloud-private-relay-ip-leak/
- `swift-tor` (concurrency-first Tor wrapper). https://github.com/21-DOT-DEV/swift-tor
- `Tor.framework` (iCepa — used by Onion Browser/Orbot). https://github.com/iCepa/Tor.framework
- Liquid Glass in SwiftUI (`glassEffect`, `GlassEffectContainer`) — Apple HIG + WWDC 2025 sessions 219/323.
- Onion Browser (reference implementation to read/fork). https://onionbrowser.com
