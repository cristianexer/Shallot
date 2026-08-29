---
name: Feature request
about: Suggest something Shallot should do
title: ''
labels: enhancement
assignees: ''
---

<!--
Please read the README's "Deliberate limitations" section first. Several
obvious-looking gaps — no obfs4 or Snowflake binary, no snapshot tests, no
system-wide tunnelling, fingerprint parity with desktop Tor Browser — are
recorded decisions with reasons attached. If you want to argue one of them
should change, that is a fine issue to open; just start from the reason that
is already written down.
-->

## What you want to be able to do

Describe the outcome rather than the implementation, if you can.

## Why the current behaviour is not enough

## Effect on anonymity

Every feature in a Tor browser is a security question. Please say what you
think this one would mean for:

* what leaves the device, and over which path;
* what is written to disk, if anything;
* whether it adds a fingerprinting surface;
* whether it adds anything that could link two tabs or two sessions.

"None of these — it is purely a UI change" is a good answer when it is true.

## How you imagine it working

Optional. If it touches the module graph — a new protocol in `Domain`, a new
implementation in a core module — sketch that here.

## Alternatives you have considered
