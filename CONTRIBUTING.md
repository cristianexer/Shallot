# Contributing to Shallot

Thank you for wanting to help. Shallot is a browser people may use because
being identified would be dangerous for them, so the bar here is a little higher
than for most apps: a change is finished when it is correct, tested, and honest
about what it does not do.

This document is the house style of *this* codebase, derived from the code that
is already here. Read a neighbouring file before you write a new one — the
existing sources are the specification for the style, and they are consistent.

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Running the gates locally

CI is two scripts, and they are the same two scripts you can run here — so a
red build is something you can reproduce and fix without pushing a commit to
find out:

```sh
.github/scripts/lint.sh    # SwiftLint --strict, blocking; swift-format, advisory
.github/scripts/test.sh    # build once, then the unit, security and UI suites
```

`test.sh` picks the same simulator CI would (the newest available iPhone), so a
timing-sensitive test that only fails on the runner usually fails here too. Pass
`SHALLOT_DEVICE_ID=<udid>` to pin a different one.

The live Tor suite and the performance suite are excluded from both, by name —
they need the real network and a quiet machine. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how to run those.

## Before you start

* For anything more than a small fix, open an issue first. Some of what looks
  like a missing feature is a recorded decision — the README's *Deliberate
  limitations* section exists so nobody has to rediscover them from the source.
* If you have found something that can leak a user's real IP address or DNS,
  **do not open a public issue**. Follow [SECURITY.md](SECURITY.md).

## Getting set up

You need Xcode 26 or later and an iOS 18 or later simulator.

```sh
git clone https://github.com/cristianexer/Shallot.git
cd Shallot
xcodebuild -project Shallot.xcodeproj -scheme Shallot -resolvePackageDependencies
open Shallot.xcodeproj
```

The first resolve builds the embedded Tor C library and OpenSSL from source and
takes several minutes. Later builds reuse it.

## The module graph, and the one rule about it

The core lives in one local Swift package, `Packages/ShallotCore`. Its
`Package.swift` records the dependency direction in a comment at the top and
then enforces it with target dependencies:

```
Features ──▶ DesignSystem ──▶ Domain
   │                            ▲
   └──▶ BrowserEngine ──────────┤
        TorKit ─────────────────┤
        Persistence ────────────┤
        Monitoring ─────────────┤
        AppLock ────────────────┘
```

**Dependencies point downward, always.** `Domain` holds models, protocols and
pure logic, plus the test doubles that implement those protocols for previews
and tests — and no framework types at all: no UIKit, no WebKit, no Tor. Nothing
above `Domain` may import a concrete implementation of anything else; the app wires
the concrete types together at launch in `Shallot/AppContainer.swift`, which is
the single place that knows which Tor library, which storage engine and which
authentication framework are in use.

Practically, this means:

* A new capability starts as a protocol in `Domain/Protocols/`, gets an
  implementation in the module that owns it, and is injected from
  `AppContainer`. If a view model has to `import TorKit` to do its job, the
  abstraction is in the wrong place.
* A new screen is a folder under `Features/`, with a `View` and an
  `@Observable` view model that depends only on protocols. That is what makes
  every screen drivable by the doubles in `Packages/ShallotCore/Sources/Domain/Testing/Mocks.swift`.
* If you find yourself wanting a dependency that points sideways or upward, say
  so in the issue rather than adding it. It usually means a type belongs in
  `Domain`.

`ShallotCore` has no test targets of its own, on purpose: the WebKit leak tests
need a host application to run a real `WKWebView`, and one command running every
suite beats two that can drift apart. Every suite therefore lives in the app
project's `ShallotTests` and `ShallotUITests`.

## Style

**Comments explain *why*, never *what*.** This is the strongest convention in
the codebase and the easiest to get wrong. A comment restating the code will be
asked for in review; a comment recording a decision, a constraint, or a
foot-gun someone else will otherwise step on is exactly what belongs there. The
existing sources are full of the latter — why SOCKS ports rather than SOCKS
auth, why the data store is configured before the web view exists, why onion
addresses are exempt from the HTTPS upgrade. Every security-critical decision
carries the reason next to it, so that a future reader cannot "simplify" it back
into a bug.

**British English**, in code and in prose: `favourites`, `behaviour`,
`initialise`, `colour`. The public API already spells it this way
(`FavouritesRepository`, `SwiftDataFavouritesRepository`), so a mixed spelling
is a real inconsistency rather than a matter of taste. User-facing strings are
full sentences with proper punctuation and typographic quotes.

**Swift 6, strict concurrency, no exceptions.** The package declares
`swiftLanguageModes: [.v6]`. Shared mutable state is an `actor` — `TorService`
is one because Tor's state is exactly that. UI types are `@MainActor`. Value
types crossing a boundary are `Sendable`. Do not reach for
`@unchecked Sendable` or `nonisolated(unsafe)` to make a warning go away; if the
compiler is complaining, the design usually is too.

**Pure functions where a decision matters.** `NavigationPolicy`,
`ChromeVisibilityPolicy`, `SocksPortPool`, `URLNormalizer` and `OnionAddress`
are deliberately free of framework types so their behaviour is tested directly
rather than through a live web view. Keep new policy code in that shape.

**Doc comments** are `///`, and every public type gets one that says what it is
for, not what it is. `/* */` blocks are flagged by the formatter and are not
used anywhere in the Swift sources.

## Linting

```sh
swiftlint lint --strict
```

This is a **blocking gate** and must be clean — CI runs exactly this command
with `--strict`, which promotes every warning to an error. `.swiftlint.yml` is
tuned so this codebase passes with zero violations, and every disabled rule
carries its reason in the file. Prefer changing your code over adding a
`// swiftlint:disable`; if a rule genuinely fights the house style, turn it off
in `.swiftlint.yml` with a comment explaining why, so the decision lives in one
place instead of being scattered through security code.

```sh
xcrun swift-format lint --recursive Packages/ShallotCore/Sources Shallot ShallotTests ShallotUITests
```

swift-format is **advisory**, and deliberately so. `.swift-format` matches the
code that is already here — four spaces, 110 columns, multi-line string
literals never reflowed, because `LeakMitigations.source(for:)` *is* the script
that runs on the page and a pretty-printer must not touch it. Beyond that, its
printer disagrees with some hand-wrapped call sites and with the full-sentence
strings shown to users, and reformatting security-critical files to satisfy a
printer is not a trade worth making. Genuine errors — a file it cannot parse —
still fail CI.

## Tests

**Every behavioural change needs a test.** Every security-relevant change needs
one in `ShallotTests/Security/`. That directory is the app's evidence that its
promises are real, and a change to a leak mitigation, the kill switch, the
proxy configuration, circuit isolation or the persistence guarantees is not
finished without one.

Tests use [Swift Testing](https://developer.apple.com/documentation/testing)
(`@Suite`, `@Test`, `#expect`, `#require`), not XCTest, except in
`ShallotUITests` where XCUITest requires it. Test names are sentences describing
the claim being checked — *"With Tor down, nothing loads — the engine refuses
and shows why"* — because a failing test name should tell you what broke without
opening the file.

Everything that runs by default is hermetic: `AppContainer.isTestHost` detects a
test host, via `XCTestConfigurationFilePath` or the `--shallot-ui-testing` launch
argument, and substitutes `MockTorService` and an in-memory model container. No
suite that runs on a pull request needs the Tor network.

```sh
# Unit, logic and security suites
xcodebuild test -project Shallot.xcodeproj -scheme Shallot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ShallotTests

# UI suites, against both size classes — the shell has two distinct layouts
xcodebuild test -project Shallot.xcodeproj -scheme Shallot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ShallotUITests
xcodebuild test -project Shallot.xcodeproj -scheme Shallot \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:ShallotUITests

# The live Tor suite — opt-in, needs a working network
touch /tmp/shallot-live-tests
xcodebuild test -project Shallot.xcodeproj -scheme Shallot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:ShallotTests/LiveTorIntegrationTests
```

Simulator model names depend on the runtimes your Xcode ships, so check with
`xcodebuild -project Shallot.xcodeproj -scheme Shallot -showdestinations`
before assuming a name exists. `-parallel-testing-enabled NO` on the live suite
is not optional: parallel clones would each start their own Tor and race for the
same public endpoint.

Any test type whose name contains `Live` or `Integration` is discovered from the
sources by CI, skipped on pull requests and run only from the manual
`live-integration` job. Naming a new suite correctly is the whole of wiring it
up.

## Test on a device

The Simulator uses the macOS networking stack, and it will mislead you about
both proxy and TLS behaviour: a route that works in the Simulator can behave
differently on device, and vice versa. Anything touching Tor, the proxy, DNS or
TLS must be checked on real hardware before you claim it works. The same applies
to Tor's lifecycle — a `stop()`-then-`start()` path appears to work in the
Simulator and wedges on device, which is precisely why there isn't one.

## Constraints you must not break

These are load-bearing. A pull request that undoes one will be closed with a
pointer back here, however good the rest of it is.

1. **The kill switch comes first.** `NavigationPolicy` checks whether Tor is
   carrying traffic *before anything else*, for every frame, main and sub. No
   condition, no fast path and no optimisation may be evaluated ahead of it.
   `about:` is the sole exempt scheme, because WebKit uses it to initialise a
   frame and it reaches no network.
2. **One Tor start per process.** The embedded Tor C library keeps
   process-global state and cannot be restarted in-process. New Identity is
   `SIGNAL NEWNYM` over the control channel, never a restart. Anything Tor only
   reads at start-up is decided before `start()`, and changing it surfaces a
   relaunch-required flow. Do not add a `stop()`-then-`start()` path.
3. **No SOCKS-auth isolation.** Per-tab circuit isolation is a bank of Tor
   `SOCKSPort` lines (`SocksPortPool`), because credentials applied through
   `ProxyConfiguration.applyCredential` are not reliably used by WebKit. It
   looks like something that could be simplified. It cannot.
4. **No telemetry of any kind.** No analytics, no crash reporting, no
   "anonymous" usage counters, no remote configuration. There is a structural
   test enforcing this — `ShallotTests/Security/NoTelemetryTests.swift` — which
   scans the shipping sources and fails if any module other than `TorKit` and
   `BrowserEngine` so much as mentions `URLSession`, `NWConnection` or a
   `dataTask`, if a known analytics SDK is imported anywhere, or if anything at
   all touches `UserDefaults`. If your change makes that suite fail, the change
   is wrong, not the test.
5. **No new persistence of browsing state.** Favourites and settings are the
   only things written to disk, and they are written with
   `FileProtectionType.complete`. History, cookies, cache, tabs and the monitor
   log stay in memory. No cloud sync — sync is a deanonymisation surface.
6. **Do not soften the honesty statement.** Shallot's fingerprint defence cannot
   match desktop Tor Browser's, the app says so in Settings, and the README says
   so at the top. Overstating protection to a journalist or an activist is the
   one mistake this project must never make.

## Pull requests

* Branch from `main`. One concern per pull request.
* Commit messages are written in the imperative and describe the change from
  the user's or the system's point of view, matching the existing history:
  *"Refuse to launch Tor twice in one process, and stop offering a retry that
  cannot work"*.
* Before you push: `swiftlint lint --strict` is clean, `ShallotTests` and
  `ShallotUITests` pass, and anything network-related has been exercised on a
  device.
* Fill in the pull request template, especially the security section. "No
  security impact" is a perfectly good answer when it is true; it just has to be
  a considered one.
* Say plainly what you did *not* do. An honest gap in a pull request is worth
  more here than a confident claim that does not survive review.
