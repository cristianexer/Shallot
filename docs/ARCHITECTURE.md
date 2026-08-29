# Architecture

How Shallot is put together, how each security control is implemented and where
it lives, and how to run the full test matrix. The [README](../README.md) is the
short version; this is the long one.

---

## Contents

- [Module graph](#module-graph)
- [Repository layout](#repository-layout)
- [Security controls](#security-controls)
- [Tor lifecycle](#tor-lifecycle)
- [Persistence, app lock, monitoring, transport](#persistence-app-lock-monitoring-transport)
- [Tests](#tests)
- [Lint](#lint)
- [CI](#ci)
- [Signing and deployment target](#signing-and-deployment-target)
- [The pluggable-transport seam](#the-pluggable-transport-seam)
- [Why there are no snapshot tests](#why-there-are-no-snapshot-tests)

---

## Module graph

Layered and dependency-inverted. The UI depends on protocols; concrete services
are constructed once in a composition root and injected. Nothing above `Domain`
ever imports a concrete implementation of anything else, which is what makes
every screen drivable by a test double and the Tor library swappable.

```
App          Shallot/            ShallotApp · AppContainer · ShallotCommands
             (thin on purpose: entry point, composition root, ⌘-shortcuts)
             ─────────────────────────────────────────────────────────────
Features     Browser · Favourites · Monitor · Settings · Shell
             each screen = View + @Observable ViewModel, protocols only
             ─────────────────────────────────────────────────────────────
Domain       Models + protocols, no implementation, no UIKit
             TorServicing · BrowsingSessioning · FavouritesRepository
             SettingsStoring · MonitorFeeding · AppLocking
             ─────────────────────────────────────────────────────────────
Core         TorKit · BrowserEngine · Persistence · Monitoring · AppLock
             DesignSystem
             ─────────────────────────────────────────────────────────────
Platform     WebKit · Network.framework · LocalAuthentication · SwiftData
             swift-tor (→ swift-openssl, swift-event)
```

The core lives in one local Swift package, `Packages/ShallotCore`, whose
`Package.swift` records the dependency direction as a comment and enforces it
with target dependencies:

| Target | Depends on | What it owns |
|---|---|---|
| `Domain` | — | Models, protocols, pure logic (`URLNormalizer`, `OnionAddress`, `BridgeLineParser`, `AsyncBroadcast`), and the mock services used by tests and previews |
| `DesignSystem` | `Domain` | Palette, typography, glass chrome, the digital-rain canvas, the privacy shield |
| `TorKit` | `Domain`, `Tor` | `TorService` actor, `ControlChannel`, `SocksPortPool`, `CircuitStatusParser`, `PluggableTransport` |
| `BrowserEngine` | `Domain` | The proxied, hardened `WKWebView`: `ProxyConfigurator`, `NavigationPolicy`, `LeakMitigations`, `WebKitFeatureFlags`, `SecurityPolicy`, `ContentBlocker`, `TabSession`, `ErrorPage` |
| `Persistence` | `Domain` | SwiftData store for favourites and settings |
| `Monitoring` | `Domain` | Local-only aggregation of Tor and engine events |
| `AppLock` | `Domain` | LocalAuthentication gate |
| `Features` | `Domain`, `DesignSystem`, `BrowserEngine` | The four screens and the adaptive shell |

`Shallot/AppContainer.swift` is the composition root and the one place that
knows which Tor library, which storage engine and which authentication framework
are in use. It also decides whether the app is running as a test host — it
checks for `XCTestConfigurationFilePath` and the `--shallot-ui-testing` launch
argument — and if so substitutes `MockTorService` and an in-memory model
container. That is why the whole default test suite is hermetic and needs no
live Tor network.

The one deliberate architectural compromise: `ShallotCore` has no test targets
of its own. Every suite lives in the app project's `ShallotTests`, because the
WebKit leak tests need a host application to run a real `WKWebView`, and one
command running every suite is worth more than two that can drift apart.

---

## Repository layout

```
Shallot/                 app target — entry point, composition root, ⌘-shortcuts,
                         Assets.xcassets, bundled geoip/geoip6
Packages/ShallotCore/    the eight core modules
ShallotTests/            Swift Testing suites — Unit/, Security/ (leak probes,
                         the no-telemetry scan, the live Tor suite), Performance/
ShallotUITests/          XCUITest suites, including the screenshot generator
Tools/make-app-icon.py   regenerates Assets.xcassets/AppIcon.appiconset/icon-1024.png
Tools/make-banner.py     regenerates docs/banner.gif — a port of
                         DesignSystem/RainView.swift to Pillow
docs/                    the banner, the screenshots and this document
.github/workflows/ci.yml build, test and lint on every PR; live suites on demand
desing files/            the build spec this was implemented against
```

---

## Security controls

Each control is a named type with a single home, so "what does this actually do"
has one answer a test can assert against.

### The kill switch and navigation rules

`BrowserEngine/NavigationPolicy.swift` — pure functions over a `Context` value,
deliberately free of WebKit types so the decisions can be tested directly rather
than through a live web view.

- Tor not carrying traffic → `.block(.torNotRunning)`, checked **before anything
  else and for every frame**, main and sub. Nothing leaves the device.
- `about:` is the sole exempt scheme: WebKit uses it to initialise a frame and it
  reaches no network, so refusing it would refuse the first frame of every tab.
- Anything outside `http`/`https` — `file:`, `data:`, `javascript:` — is blocked
  as a scheme that can reach outside the Tor connection.
- HTTPS-only upgrades `http` → `https` and blocks if the upgrade has already been
  tried and failed, so a site with no HTTPS listener produces a clear error
  rather than a redirect loop. Onion addresses are exempt: the address itself
  authenticates and encrypts the connection.
- Malformed v3 onion addresses are refused rather than handed to the resolver.

### Proxy routing

`BrowserEngine/ProxyConfigurator.swift` — three rules, each documented in place:
SOCKS5 rather than HTTP CONNECT (WebKit's HTTP-CONNECT path has known bugs, and
SOCKS5 hands the hostname to Tor for remote resolution, which is what keeps DNS
off the device); the data store is configured fully **before** the `WKWebView`
exists, because mutating `proxyConfigurations` on a live view interrupts
networking and has been reported to crash on iOS 18; and one non-persistent
store per tab, so nothing reaches disk and two tabs share no cookies, cache or
storage. `isProxied(_:)` is the assertion the engine and the leak tests both use
before anything is allowed to load.

The routing itself is `WKWebsiteDataStore.proxyConfigurations` with a SOCKS5
endpoint pointed at the in-process Tor — public API, no entitlement required.

### Per-tab circuit isolation

`TorKit/SocksPortPool.swift`. Desktop Tor Browser isolates per first-party domain
with SOCKS username/password and `IsolateSOCKSAuth`. **That does not work on
WKWebView** — credentials applied through `ProxyConfiguration.applyCredential`
are not reliably used. So `TorService` opens a bank of Tor `SOCKSPort` lines
(eight by default, `isolationPoolSize`) and points each tab's data store at a
different one; every port additionally carries `IsolateDestAddr IsolateDestPort`
so two sites visited in the same tab also get separate circuits. Assignment is
stable per tab, released on close, and past capacity keys share the least-loaded
port — degraded isolation beats refusing to open a tab. This is a correctness
decision, not an accident; do not simplify it back to SOCKS auth.

### WebKit proxy-bypass mitigations

`BrowserEngine/LeakMitigations.swift` and `BrowserEngine/WebKitFeatureFlags.swift`.

Independent research published in August 2026 documented three WebKit features
that reach the network *outside* a configured proxy and leak the device's real IP
and DNS regardless of how carefully the proxy is set. They are not fixed at the
OS level. WebRTC is a fourth of the same kind.

| Bypass | What leaks | Mitigation |
|---|---|---|
| DNS prefetching (`<link rel="dns-prefetch">`, honoured since iOS 26) | Hostname resolved on the device's normal DNS path | `x-dns-prefetch-control: off` injected as a `<meta>`, plus a `MutationObserver` that strips `dns-prefetch`, `preconnect`, `prefetch` and `prerender` hints as they arrive |
| WebAuthn related-origin requests | Real IP, **with no user interaction at all** — the worst of the three | `navigator.credentials`, `PublicKeyCredential` and the authenticator response types removed |
| WebTransport | Real IP, direct connection | `WebTransport` and its stream types removed |
| WebRTC | Local and public addresses via ICE candidate gathering | `RTCPeerConnection` and the `getUserMedia` family removed |

There are **two layers, and only one of them is guaranteed.** The user script is
installed at `.atDocumentStart` for all frames, including sub-frames — a
third-party iframe is exactly where an unwanted prefetch or RTC probe turns up —
so it runs before any page script and a page can never capture a reference to an
API before it is removed. Where deletion is impossible because a property is
non-configurable, it is redefined as a getter returning `undefined` that reports
the attempt. Every blocked attempt is posted to a message handler and appears in
the Monitor's event log.

`WebKitFeatureFlags` is the second layer and is **best-effort by design**. It
turns the same features off inside the engine through `+[WKPreferences _features]`
and `-[WKPreferences _setEnabled:forFeature:]` — SPI, not public API. The key
strings move between releases, so it matches case-insensitive *fragments* rather
than exact names, guards every call with a runtime check, never throws and never
crashes, and returns an `Outcome` saying exactly what it managed to disable and
what this OS did not expose. If it disables nothing at all the app is still
protected; it simply protects at the JavaScript boundary rather than inside the
engine. Every SPI name lives in that one file, so when Apple ships the OS-level
fix there is one place to revisit.

**If you are reasoning about whether a leak is closed, reason about the user
script.**

Per-site opt-in re-enablement is available in Settings, off by default;
`LeakMitigations.Configuration(settings:host:)` is where a user's exception is
resolved for a given host.

### Security levels and content blocking

`BrowserEngine/SecurityPolicy.swift` maps `.standard | .safer | .safest` onto
WebKit configuration; the shipping default is **Safer**. Safest sets
`allowsContentJavaScript = false`, which on an engine we cannot patch is the
strongest realistic anti-fingerprinting lever there is. All levels get autoplay
off, picture-in-picture off and `upgradeKnownHostsToHTTPS`.

`BrowserEngine/ContentBlocker.swift` compiles two `WKContentRuleList`s — a base
list of third-party trackers plus `make-https`, and a strict list that
additionally blocks remote fonts and third-party scripts — enforced below the
JavaScript layer, which catches sub-resources that never reach the navigation
delegate. It is not an ad blocker: every entry is a host that exists to follow
people between sites. The `make-https` rule deliberately excludes onion domains
and top-level documents: an onion address already authenticates and encrypts the
connection end to end and almost no onion service listens on 443, so upgrading
one does not add security, it breaks the page. Top-level navigation is
`NavigationPolicy`'s job, because that is the only place that knows about the
exemption.

### Chrome

`Features/Browser/OmniBar.swift` is one row: back only when there is somewhere
to go back to, reload inside the pill, and everything that is not needed on
every page — new identity, saving a favourite, the security level — behind the
overflow menu. The leading glyph in the pill is the connection's security when
Tor is up and its bootstrap progress when it is not, because that is the state
worth the space.

`BrowserEngine/ChromeVisibilityPolicy.swift` decides when the chrome gets out of
the way. It is pure arithmetic over the scroll offset — hysteresis so an
inertial wobble cannot make it flicker, always visible near the top, and never
hideable on a page shorter than the viewport, because there would be no way to
scroll back up for it. The engine watches `contentOffset` through KVO rather
than taking the scroll view's delegate, which WebKit owns.

---

## Tor lifecycle

`TorKit/TorService.swift`, an `actor`, and the only type in the app that imports
the Tor library at all. The embedded Tor C library keeps process-global state and
**cannot be restarted inside the same process** once stopped, so: Tor starts
exactly once per launch; New Identity is `SIGNAL NEWNYM` over the control
channel, never a restart; and configuration Tor only reads at start-up — bridges,
the SOCKS port bank — is decided before `start()`, with a change surfacing a
relaunch-required flow in Settings. There is no `stop()`-then-`start()` path, and
adding one would appear to work in the Simulator and wedge on device.

The consensus cache is persistent on purpose (`AppContainer.torCacheDirectory()`):
it turns a ~40-second cold bootstrap into a 5–10 second warm one, and holds only
the public directory every Tor client downloads. GeoIP databases are bundled and
resolved on-device, so relay country labels in the Monitor cost no network call.

---

## Persistence, app lock, monitoring, transport

- **Persistence** — `Persistence/` stores favourites and settings only, via
  SwiftData, with `FileProtectionType.complete` applied to the store directory
  and to the store file and its `-wal`/`-shm` sidecars (SwiftData has no API for
  this, so `ShallotModelContainer` sets the protection class directly). A seized,
  locked device yields nothing — not even the list of onion services someone
  thought worth saving. No browsing history is ever written; cookies, cache, page
  data, tabs and monitor logs are all in-memory. No cloud sync: sync is a
  deanonymisation surface.
- **App lock** — `AppLock/AppLockService.swift` gates entry with Face ID, Touch
  ID or the device passcode; `DesignSystem/PrivacyShield.swift` covers the app
  when the scene goes inactive so the app-switcher snapshot never shows a page.
  `NSFaceIDUsageDescription` is in `Info.plist`.
- **Monitoring** — `Monitoring/MonitorService.swift` aggregates circuit chain,
  bootstrap progress, bandwidth and the security-event log. All computed locally,
  into a bounded in-memory ring buffer. No telemetry, no analytics, no crash
  reporting: there is no network egress except Tor's own and loopback.
- **Transport security** — ATS stays on for the app's own networking.
  `NSAllowsArbitraryLoadsInWebContent` is set because onion services almost never
  serve TLS and a browser that cannot load `http://` is not a browser; Shallot's
  own HTTPS-only mode, on by default and implemented in `NavigationPolicy`, is
  the control that actually governs insecure page loads.

---

## Tests

Every suite that runs by default is hermetic: `AppContainer` detects a test
host and swaps in `MockTorService` and an in-memory store, so nothing below
needs the Tor network. The one exception is `LiveTorIntegrationTests`, which is
opt-in and covered further down.

```sh
# Unit, logic and security suites (Swift Testing)
xcodebuild test \
  -project Shallot.xcodeproj -scheme Shallot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ShallotTests

# UI suites (XCUITest)
xcodebuild test \
  -project Shallot.xcodeproj -scheme Shallot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ShallotUITests

# Everything
xcodebuild test \
  -project Shallot.xcodeproj -scheme Shallot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Any iOS 18-or-later simulator works, but **which model names exist depends on
the runtimes your Xcode ships** — `name=iPhone 16 Pro` fails on a machine whose
newest runtime has no iPhone 16 Pro, because xcodebuild resolves the name
against `OS:latest`. List what is actually there first:

```sh
xcodebuild -project Shallot.xcodeproj -scheme Shallot -showdestinations
xcrun simctl list devices available
```

CI does exactly that and picks the last iPhone `-showdestinations` reports,
which cannot be older than the deployment target. The adaptive shell has two
distinct layouts, so it is worth running the UI suite against both size classes:

```sh
-destination 'platform=iOS Simulator,name=iPhone 17 Pro'           # compact
-destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'   # regular
```

### The hermetic security suites

Two security suites run on **every pull request**.

`ShallotTests/Security/WebKitLeakTests.swift` builds a real `WKWebView` exactly
as the app does, loads probe pages from strings so nothing leaves the machine,
and asserts that DNS-prefetch hints are stripped — including ones injected by
script after load — that `WebTransport`, WebAuthn and `RTCPeerConnection` are
unreachable from a page, that a per-site opt-in restores a feature *and only for
that site*, that every data store is proxied and non-persistent, and that with
Tor down nothing loads at all.

`ShallotTests/Security/NoTelemetryTests.swift` scans the shipping sources and
fails the build if any module other than `TorKit` and `BrowserEngine` so much as
mentions a networking API, if a known analytics SDK is imported anywhere, or if
anything at all touches `UserDefaults`.

### The live Tor suite

`ShallotTests/Security/LiveTorIntegrationTests.swift` bootstraps a real Tor
against the real network and checks the promises this app makes, one test per
claim:

- **Tor bootstraps** and reports its version back over the control channel.
- **A three-hop circuit is built**, and at least one relay resolves to a country
  from the *bundled* GeoIP databases — proving the Monitor's country labels cost
  no network lookup.
- **Traffic really goes through Tor.** `check.torproject.org/api/ip` returns
  `IsTor: true` over a proxied connection, the same endpoint fetched directly
  returns `IsTor: false`, and the two addresses differ.
- **The app's own web view is routed too.** Not a `URLSession` standing in for
  the browser: the exact `WKWebView` the app builds — same proxy configuration,
  same ephemeral data store, same document-start user scripts — loads that
  endpoint and its document body contains `"IsTor":true`.
- **Two tabs leave by two different exit relays.** Two isolation keys get two
  different SOCKS ports, and the two exit addresses do not match. If they ever
  do, circuit isolation has silently collapsed.
- **Onion services load**, in that same web view, at two independent addresses —
  the Tor Project's own and a second one, because one service being up proves
  less than two. `.onion` through `URLSession` would fail instantly, since
  CFNetwork's SOCKS support resolves hostnames locally; that it works through
  `proxyConfigurations` is the observable form of "DNS never happens on this
  device".
- **The Monitor is wired to reality**: real circuits, real bandwidth samples,
  bootstrap at 100, all computed on-device.
- **New Identity works**, and traffic still flows after `SIGNAL NEWNYM`.

It is skipped unless switched on. `xcodebuild` does not forward its own
environment into a test host running in the simulator, so the switch is a marker
file on the shared filesystem:

```sh
touch /tmp/shallot-live-tests
xcodebuild test \
  -project Shallot.xcodeproj -scheme Shallot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:ShallotTests/LiveTorIntegrationTests
```

`-parallel-testing-enabled NO` matters: parallel clones would each start their
own Tor and race for the same public endpoint. The suite is `.serialized` and
shares one Tor across its tests for the same reason — a second `start()` in one
process is not a fresh Tor, it is undefined behaviour. Setting
`SHALLOT_LIVE_TESTS=1` works too where the environment does reach the test host.

---

## Lint

```sh
swiftlint lint --strict                       # blocking gate; must be clean
xcrun swift-format lint --recursive Packages/ShallotCore/Sources Shallot ShallotTests ShallotUITests
```

`.swiftlint.yml` is tuned so `--strict` passes with zero violations on this
codebase; the rules that are off are off deliberately and each carries its
reason in the file. `.swift-format` matches the code that is already here — four
spaces, a 110-column target, multi-line string literals never reflowed, because
`LeakMitigations.source(for:)` *is* the script that runs on the page. swift-format
runs advisory rather than blocking: its pretty-printer disagrees with some
hand-wrapped call sites and with the full-sentence strings shown to users, and
reformatting security-critical files to satisfy a printer is not a trade worth
making.

---

## CI

Anything whose test or suite name contains `Live` or `Integration` needs the
real network. CI discovers those from the sources, skips them in the
pull-request job and runs them only from the manually-triggered
`live-integration` job, alongside the performance suite. See
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml). Naming a new suite
correctly is the whole of wiring it up.

CI runs the live job manually and never on a pull request: Tor exit traffic from
shared runners is frequently blocked or captcha'd, and a flaky gate is one people
learn to ignore.

The first package resolve builds the embedded Tor C library and OpenSSL from
source and takes several minutes. Subsequent builds reuse it; CI caches it.

---

## Signing and deployment target

The build spec asks for iOS 17, because that is the floor for
`proxyConfigurations`, SwiftData and `@Observable`. The shipping floor is
**iOS 18**, forced by `swift-tor` declaring `.iOS(.v18)` in its own manifest —
and an embedded Tor is not something this app can do without.
`Packages/ShallotCore/Package.swift` records this in a named constant, `iOSFloor`,
so the reason travels with the decision, and `IPHONEOS_DEPLOYMENT_TARGET` on the
app target matches at 18.0.

Signing is standard automatic signing; the in-app proxy route needs **no special
entitlement**, because `proxyConfigurations` is public API. Only a system-wide
`NEPacketTunnelProvider` tunnel — explicitly out of scope — would need the
Network Extension entitlement.

Run on a **real device** for anything touching Tor or networking. The Simulator
uses the macOS networking stack and will mislead you about proxy and TLS
behaviour.

---

## The pluggable-transport seam

obfs4 and Snowflake do not work in this build. Both are Go programs that on iOS
are linked in as a framework (IPtProxy is the usual one) running in-process on a
loopback SOCKS port that Tor dials with `ClientTransportPlugin`. That binary is
roughly 140 MB and the decision to ship it belongs to whoever ships the app, so
it is not bundled. What exists instead is the seam:
`TorKit/PluggableTransport.swift` defines `PluggableTransportProviding`, and
`AppContainer.liveTorConfiguration(bridges:)` passes `transportProvider: nil`
with a comment marking the spot. Registering a provider there is the whole
change. Until one is registered, **plain bridges work in full**, and the
obfuscating transports are shown in Settings as unavailable with the reason —
via `TransportAvailability` — rather than offered and then quietly failing to
connect on exactly the censored network where a user most needs them to work.

---

## Why there are no snapshot tests

The build spec asks for `swift-snapshot-testing` across device sizes, Dynamic
Type sizes and Reduce Motion. Adding it means giving `ShallotTests` a Swift
package dependency, and doing that forces Xcode to build the whole package graph
as dynamic frameworks so the app and the test bundle can share it — at which
point `libcrypto` fails to link, because it resolves two symbols out of `libssl`
that only exist once everything is statically linked into one binary. The suites
are in one target for exactly that reason (see the note at the top of
`Packages/ShallotCore/Package.swift`). Layout regressions are covered instead by
the XCUITest accessibility audits and the UI suites, which run against both size
classes. Restoring snapshot testing means either vendoring the library's source
into the test target or fixing the upstream `libcrypto`/`libssl` split — neither
is a five-minute job, and pretending otherwise in a comment would be worse than
saying so here.

---

Back to the [README](../README.md).
