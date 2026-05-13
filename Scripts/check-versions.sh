#!/usr/bin/env bash
#
# 0.5.0 CI gate (AGENTS.md §13): require that the macOS and iOS app
# bundles ship the same MARKETING_VERSION before tagging. Catches the
# class of regression where someone bumps `App/Info.plist` but forgets
# `AppiOS/project.yml` (or vice-versa) and the released DMG +
# TestFlight build diverge.
#
# Invoked from:
#   - `.github/workflows/ci.yml` on every PR + push (warn-only? no —
#     fail. Drift between platforms is always a release-blocking bug).
#   - `.github/workflows/release.yml` as the first step before
#     anything else runs.
#
# Exit codes:
#   0 — versions match
#   1 — drift detected (prints diff)
#   2 — could not read one of the version sources

set -euo pipefail

cd "$(dirname "$0")/.."

mac_plist="App/Info.plist"
ios_yml="AppiOS/project.yml"

if [[ ! -f "$mac_plist" ]]; then
    echo "ERROR: $mac_plist not found" >&2
    exit 2
fi
if [[ ! -f "$ios_yml" ]]; then
    echo "ERROR: $ios_yml not found" >&2
    exit 2
fi

# Pull CFBundleShortVersionString out of the macOS plist.
mac_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$mac_plist" 2>/dev/null || true)
if [[ -z "$mac_version" ]]; then
    echo "ERROR: could not read CFBundleShortVersionString from $mac_plist" >&2
    exit 2
fi

# Pull MARKETING_VERSION out of the xcodegen spec. The grep is
# anchored on the indented-yaml key to avoid matching a per-target
# setting elsewhere in the file.
ios_version=$(awk '/^        MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' "$ios_yml")
if [[ -z "$ios_version" ]]; then
    echo "ERROR: could not read MARKETING_VERSION from $ios_yml" >&2
    exit 2
fi

echo "macOS CFBundleShortVersionString: $mac_version"
echo "iOS  MARKETING_VERSION:           $ios_version"

if [[ "$mac_version" != "$ios_version" ]]; then
    cat >&2 <<EOF

ERROR: macOS and iOS versions diverge.
  macOS ($mac_plist):              $mac_version
  iOS   ($ios_yml MARKETING_VERSION): $ios_version

Bump both before tagging. AGENTS.md §13: macOS + iOS MARKETING_VERSION
must align on every release.
EOF
    exit 1
fi

echo "OK: versions match ($mac_version)"
