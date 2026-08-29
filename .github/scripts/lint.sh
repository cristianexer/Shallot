#!/usr/bin/env bash
#
# The style gate, exactly as CI runs it. Run it here before pushing:
#
#     .github/scripts/lint.sh
#
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "==> SwiftLint (blocking)"
if ! command -v swiftlint >/dev/null; then
    echo "::error::SwiftLint is not installed. brew install swiftlint" >&2
    exit 1
fi
# --strict promotes every warning to an error. .swiftlint.yml is configured to
# be clean on this codebase, so a violation here is a real one.
swiftlint lint --strict --quiet
echo "    clean"

echo "==> swift-format (advisory)"
# Its pretty-printer disagrees with some hand-wrapped call sites and with prose
# string literals shown to the user, and reformatting security-critical files to
# satisfy a printer is not a trade worth forcing. Genuine errors — a file it
# cannot parse, a broken .swift-format — still fail this script.
if xcrun --find swift-format >/dev/null 2>&1; then
    xcrun swift-format lint --recursive \
        Packages/ShallotCore/Sources Shallot ShallotTests ShallotUITests \
        2>&1 | grep -E "error:" && {
            echo "::error::swift-format reported an error, not a style opinion." >&2
            exit 1
        }
    echo "    no errors"
else
    echo "    swift-format not found in the toolchain; skipped"
fi
