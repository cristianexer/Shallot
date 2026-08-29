---
name: Bug report
about: Something in Shallot behaves incorrectly
title: ''
labels: bug
assignees: ''
---

<!--
STOP if this is a leak.

If the bug can cause a request to leave the device outside Tor, or can reveal a
real IP address or DNS query, do not file it here. Email dcristian353@gmail.com
instead — see SECURITY.md.
-->

## What happens

A clear description of the incorrect behaviour.

## What you expected

## Steps to reproduce

1.
2.
3.

## Environment

* Shallot commit or version:
* Device or simulator (and which model):
* iOS version:
* Xcode version (if you built it yourself):

## Settings in effect

These change behaviour a great deal, so please say which were on:

* Security level: Standard / Safer / Safest
* HTTPS-only: on / off
* Bridges: off / plain bridges / obfs4 / Snowflake
* Any per-site opt-ins granted for WebAuthn, WebTransport or WebRTC:

## Tor state at the time

Was Tor bootstrapped and carrying traffic? If the Monitor screen was showing
anything relevant — bootstrap progress, the circuit, a security event — please
say what.

## Anything from the Monitor's event log

Blocked loads and leak reports appear there. Redact anything you would rather
not publish, including hostnames.

<!--
Please do not paste addresses you have visited, or anything that identifies you.
A description of the kind of site is usually enough.
-->

## Anything else
