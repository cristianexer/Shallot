# Security policy

Shallot is an anonymity tool. A bug in it is not an inconvenience; it is
somebody's real IP address arriving somewhere it should never have gone. Please
report privately and give me a chance to fix it before it is public.

## Reporting a vulnerability

Email **dcristian353@gmail.com**. Please do not open a public issue for anything
that could deanonymise a user.

A report is most useful when it contains:

* what leaks, and the path it takes out of the device;
* the iOS version, device or simulator, and the Shallot commit you tested;
* a minimal page or test that demonstrates it — a failing case in
  `ShallotTests/Security/` is the ideal form, because it becomes the regression
  test;
* whether it needs user interaction, and whether it works with JavaScript
  disabled (security level **Safest**).

If you would rather not send details by plain email, send a short note saying so
and we will agree on a channel first.

## What is in scope

Anything that can cause a request to leave the device outside Tor, or that
reveals the real IP address or DNS resolution of the user. Concretely:

* a navigation, sub-resource or background request that reaches the network
  without going through the SOCKS5 proxy;
* any hostname resolved on the device rather than remotely by Tor;
* a way past the kill switch — anything loading while Tor is not carrying
  traffic;
* a bypass of the `.atDocumentStart` mitigations in `LeakMitigations`: getting a
  usable reference to `WebTransport`, `navigator.credentials`,
  `RTCPeerConnection` or a DNS-prefetch hint that survives to resolution;
* a collapse of per-tab circuit isolation — two tabs that should be on separate
  SOCKS ports sharing one, or a released port being reused in a way that links
  sessions;
* a failure of the HTTPS-only rules, or an onion address being handed to a
  local resolver;
* browsing state reaching disk: history, cookies, cache or page data written
  anywhere, or favourites and settings stored without
  `FileProtectionType.complete`;
* any outbound request from a module other than `TorKit` and `BrowserEngine` —
  that is telemetry by definition, and `ShallotTests/Security/NoTelemetryTests.swift`
  exists to make it impossible to add by accident;
* anything that defeats the app lock or the app-switcher privacy shield.

Bugs in the app that are not anonymity bugs — a crash, a layout problem, a
broken control — are welcome as ordinary public issues.

## What is out of scope

**Browser-fingerprint parity with desktop Tor Browser.** iOS requires every
browser to render with Apple's WebKit; third-party engines are forbidden outside
the EU's narrow DMA exception. Shallot cannot patch the engine, so canvas, WebGL,
font metrics, screen dimensions and similar surfaces still largely reflect the
device. A report that Shallot is fingerprintable where desktop Tor Browser is not
is describing a known and documented limitation, not a vulnerability — it is
stated in the README and in the app's own Settings screen. What *is* in scope is
a fingerprinting surface that survives security level **Safest**, where
JavaScript is off entirely, because that would mean a control is not doing what
it claims.

Also out of scope:

* the absence of obfs4 and Snowflake — deliberate, see the README; the seam is
  `PluggableTransportProviding`;
* attacks that assume an already-compromised device (jailbreak, malware,
  attacker with the passcode);
* traffic-confirmation attacks by a global passive adversary, which are a
  property of Tor's threat model rather than of this app;
* deanonymisation the user performs themselves, such as logging into a personal
  account;
* vulnerabilities in Tor itself or in `swift-tor` — report those to
  [the Tor Project](https://onionservices.torproject.org/apps/base/security/)
  and [21-DOT-DEV/swift-tor](https://github.com/21-DOT-DEV/swift-tor)
  respectively, though I would like to know so Shallot can pin or work around;
* findings from an automated scanner with no demonstrated path to a leak.

## What to expect

Shallot has one maintainer, working on it in his own time. So, honestly:

* **Acknowledgement within 7 days.** If you have not heard anything by then,
  send a reminder — it means the mail went astray.
* **An assessment within 14 days**, saying whether I agree it is a leak, how
  severe I think it is, and what I plan to do.
* **A fix as fast as the severity deserves.** Anything that leaks the real IP
  address goes to the front of the queue. Lesser issues are fixed in the normal
  flow of work.
* **Public disclosure once a fix is on `main`**, with credit to you unless you
  ask otherwise. If a fix is going to take longer than 90 days, I will say so
  and we can agree on a date rather than letting it drift.

There is no bug bounty and no money behind this project. What I can offer is a
fast, honest answer and your name in the commit and release notes.
