## What this changes

A short description, and the issue it closes if there is one.

## Why

The reasoning, not the diff. If the change encodes a constraint or a foot-gun,
that reasoning belongs in a comment in the source as well — this codebase
explains *why*, never *what*.

## Security impact

Answer this even if the answer is "none".

- [ ] This change cannot cause a request to leave the device outside Tor.
- [ ] This change does not weaken the kill switch, and nothing is evaluated
      ahead of the Tor-carrying-traffic check.
- [ ] This change does not weaken per-tab circuit isolation, and does not
      replace the SOCKS port bank with SOCKS-auth isolation.
- [ ] This change adds no telemetry, analytics, crash reporting or remote
      configuration, and `NoTelemetryTests` still passes.
- [ ] This change writes nothing new to disk, or writes it with
      `FileProtectionType.complete` and explains why it must persist.
- [ ] This change does not overstate Shallot's protection anywhere in the UI,
      the README or the docs.

If any box is unticked, explain here rather than removing it.

## Tests

- [ ] Behavioural changes have tests.
- [ ] Security-relevant changes have a test in `ShallotTests/Security/`.
- [ ] `ShallotTests` passes.
- [ ] `ShallotUITests` passes, on both a compact and a regular size class if the
      change touches the shell.

Which suites did you actually run, and on what?

## Checks

- [ ] `swiftlint lint --strict` is clean.
- [ ] Prose and identifiers use British English.
- [ ] Swift 6 strict concurrency, with no new `@unchecked Sendable` or
      `nonisolated(unsafe)`.

## Device testing

The Simulator uses the macOS networking stack and will mislead you about proxy
and TLS behaviour. If this touches Tor, the proxy, DNS or TLS, say what you ran
on real hardware and what you saw.

- [ ] Not applicable — this change touches no networking.

## What you did not do

Known gaps, things left for a follow-up, anything you are unsure about. This is
the most useful section in the template; please do not leave it empty out of
politeness.
