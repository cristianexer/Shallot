#!/usr/bin/env bash
#
# The test gate, exactly as CI runs it. Run it here before pushing:
#
#     .github/scripts/test.sh                 # picks a simulator for you
#     SHALLOT_DEVICE_ID=<udid> .github/scripts/test.sh
#
# Builds once, then runs the hermetic suites. The live Tor suite and the
# performance suite are excluded — they need the real network and a machine
# nobody else is using, and belong to the manual job.
set -euo pipefail
cd "$(dirname "$0")/../.."

DERIVED=${SHALLOT_DERIVED_DATA:-DerivedData}
UNSIGNED=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)

udid=${SHALLOT_DEVICE_ID:-$(.github/scripts/pick-simulator.sh)}
destination="platform=iOS Simulator,id=$udid"
echo "==> Simulator $udid"

# Any test type whose name contains Live or Integration needs the real network.
# They are discovered from the sources rather than listed here, so naming one
# correctly is all it takes to keep it off the pull-request lane.
skips=()
while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    if grep -rql "$suite" --include='*.swift' ShallotUITests 2>/dev/null; then
        skips+=("-skip-testing:ShallotUITests/$suite")
    else
        skips+=("-skip-testing:ShallotTests/$suite")
    fi
done < <(
    grep -rhoE '^ *(public |internal |final )*(class|struct) +[A-Za-z0-9_]*(Live|Integration)[A-Za-z0-9_]*' \
        --include='*.swift' ShallotTests ShallotUITests 2>/dev/null \
        | awk '{ print $NF }' | sort -u
)
# Timings from a shared runner are noise, and a noisy gate is one people learn
# to ignore.
skips+=("-skip-testing:ShallotTests/PerformanceTests")
echo "==> Skipping: ${skips[*]}"

run() {
    if command -v xcbeautify >/dev/null; then
        "$@" | xcbeautify --renderer "${XCBEAUTIFY_RENDERER:-terminal}"
    else
        "$@"
    fi
}

echo "==> Build for testing"
set -o pipefail
run xcodebuild build-for-testing \
    -project Shallot.xcodeproj -scheme Shallot \
    -destination "$destination" -derivedDataPath "$DERIVED" "${UNSIGNED[@]}"

echo "==> Unit, logic and security suites"
run xcodebuild test-without-building \
    -project Shallot.xcodeproj -scheme Shallot \
    -destination "$destination" -derivedDataPath "$DERIVED" \
    -only-testing:ShallotTests "${skips[@]}" \
    -resultBundlePath TestResults-Unit.xcresult "${UNSIGNED[@]}"

echo "==> UI suites"
run xcodebuild test-without-building \
    -project Shallot.xcodeproj -scheme Shallot \
    -destination "$destination" -derivedDataPath "$DERIVED" \
    -only-testing:ShallotUITests "${skips[@]}" \
    -resultBundlePath TestResults-UI.xcresult "${UNSIGNED[@]}"

echo "==> All suites passed"
