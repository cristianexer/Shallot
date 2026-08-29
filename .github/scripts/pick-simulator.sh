#!/usr/bin/env bash
#
# Prints the UDID of an iPhone simulator to test on, creating one if the image
# has a runtime but no ready device.
#
# This used to parse `xcodebuild -showdestinations`, which needs the scheme's
# packages resolved, changes format between releases, and says nothing useful
# when it comes back empty. `simctl` is the source of truth and answers in
# milliseconds.
set -euo pipefail

pick() {
    xcrun simctl list devices available --json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin).get("devices", {})
best = None
for runtime, devices in data.items():
    if "iOS" not in runtime:
        continue
    # Runtime keys look like com.apple.CoreSimulator.SimRuntime.iOS-18-4;
    # the trailing numbers order them the way a human would read them.
    version = tuple(int(part) for part in runtime.split("iOS-")[-1].split("-") if part.isdigit())
    for device in devices:
        if not device.get("isAvailable"):
            continue
        if not device.get("name", "").startswith("iPhone"):
            continue
        key = (version, device["name"])
        if best is None or key > best[0]:
            best = (key, device["udid"])
print(best[1] if best else "")
'
}

udid=$(pick)

if [ -z "$udid" ]; then
    echo "No ready iPhone simulator; trying to create one." >&2
    runtime=$(xcrun simctl list runtimes --json 2>/dev/null | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin).get("runtimes", []) if r.get("isAvailable") and "iOS" in r.get("identifier", "")]
runtimes.sort(key=lambda r: [int(p) for p in r.get("version", "0").split(".") if p.isdigit()])
print(runtimes[-1]["identifier"] if runtimes else "")
')
    if [ -n "$runtime" ]; then
        device_type=$(xcrun simctl list devicetypes --json 2>/dev/null | python3 -c '
import json, sys
types = [t for t in json.load(sys.stdin).get("devicetypes", []) if t.get("name", "").startswith("iPhone")]
print(types[-1]["identifier"] if types else "")
')
        if [ -n "$device_type" ]; then
            xcrun simctl create "ci-iphone" "$device_type" "$runtime" >/dev/null 2>&1 || true
            udid=$(pick)
        fi
    fi
fi

if [ -z "$udid" ]; then
    # Everything below is here so a future failure is diagnosable from the log
    # rather than from a bare "no simulator".
    echo "::error::No iOS simulator available on this runner." >&2
    echo "--- xcodebuild -version" >&2; xcodebuild -version >&2 || true
    echo "--- simctl runtimes" >&2; xcrun simctl list runtimes >&2 || true
    echo "--- simctl devices" >&2; xcrun simctl list devices >&2 || true
    exit 1
fi

echo "$udid"
