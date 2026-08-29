#!/usr/bin/env bash
#
# Selects the newest installed Xcode that meets MINIMUM_XCODE.
#
# Runner images rename their Xcode bundles between releases, so pinning
# DEVELOPER_DIR to one path fails as an unrelated "command not found" months
# later. This fails loudly and says exactly what it wanted instead.
set -euo pipefail

minimum="${MINIMUM_XCODE:-26.0}"

best_path=""
best_version="0"
for app in /Applications/Xcode*.app; do
    [ -d "$app" ] || continue
    plist="$app/Contents/version.plist"
    [ -f "$plist" ] || continue
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || echo "0")
    # `sort -V` orders version strings the way humans read them.
    newest=$(printf '%s\n%s\n' "$version" "$best_version" | sort -V | tail -1)
    if [ "$newest" = "$version" ] && [ "$version" != "$best_version" ]; then
        best_version="$version"
        best_path="$app"
    fi
done

if [ -z "$best_path" ]; then
    echo "::error::No Xcode found in /Applications."
    exit 1
fi

acceptable=$(printf '%s\n%s\n' "$best_version" "$minimum" | sort -V | tail -1)
if [ "$acceptable" != "$best_version" ]; then
    echo "::error::Xcode $minimum or newer is required; the newest installed is $best_version."
    exit 1
fi

echo "Selecting Xcode $best_version at $best_path"
sudo xcode-select -s "$best_path/Contents/Developer"
