#!/usr/bin/env bash
# Slice the master 1024×1024 icon into every legacy iOS app-icon size
# the App Store Connect validator wants to see in the bundle's asset
# catalog. Idempotent — re-running just overwrites the same files.
#
# Why we don't rely on the "single universal 1024" workflow alone:
# Xcode 16+ supports a single 1024×1024 universal icon and asks
# `actool` to derive the rest, but ASC's upload validator (separate
# pipeline) checks for the actual pre-rendered files and rejects with:
#
#   Validation failed (409) Missing required icon file. The bundle
#   does not contain an app icon for iPhone / iPod Touch of exactly
#   '120x120' pixels, in .png format ...
#
# Pre-generating every size up-front avoids the asymmetry between
# what the Xcode build accepts and what ASC accepts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="${REPO_ROOT}/Resources/icon-master.png"
OUT_DIR="${REPO_ROOT}/AppiOS/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "${MASTER}" ]]; then
    echo "Master icon missing at ${MASTER}" >&2
    echo "Run: swift Scripts/make-icon.swift" >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

# (output_filename, pixel_size). Covers the full "Apple-prescribed iOS
# app icon set" — iPhone notification/settings/spotlight/app at 2x and
# 3x, iPad notification/settings/spotlight/app at 1x and 2x, the iPad
# Pro 83.5pt @2x app icon, and the App Store marketing icon.
declare -a TARGETS=(
    "icon-20@2x.png:40"          # iPhone notification 20pt @2x
    "icon-20@3x.png:60"          # iPhone notification 20pt @3x
    "icon-29@2x.png:58"          # iPhone settings 29pt @2x
    "icon-29@3x.png:87"          # iPhone settings 29pt @3x
    "icon-40@2x.png:80"          # iPhone spotlight 40pt @2x
    "icon-40@3x.png:120"         # iPhone spotlight 40pt @3x
    "icon-60@2x.png:120"         # iPhone app 60pt @2x  ← required by ASC
    "icon-60@3x.png:180"         # iPhone app 60pt @3x  ← required by ASC
    "icon-20-ipad.png:20"        # iPad notification 20pt @1x
    "icon-20-ipad@2x.png:40"     # iPad notification 20pt @2x
    "icon-29-ipad.png:29"        # iPad settings 29pt @1x
    "icon-29-ipad@2x.png:58"     # iPad settings 29pt @2x
    "icon-40-ipad.png:40"        # iPad spotlight 40pt @1x
    "icon-40-ipad@2x.png:80"     # iPad spotlight 40pt @2x
    "icon-76-ipad.png:76"        # iPad app 76pt @1x
    "icon-76-ipad@2x.png:152"    # iPad app 76pt @2x   ← required by ASC
    "icon-83.5-ipad@2x.png:167"  # iPad Pro app 83.5pt @2x
    "icon-1024.png:1024"         # App Store marketing icon
)

for target in "${TARGETS[@]}"; do
    name="${target%%:*}"
    size="${target##*:}"
    sips -z "${size}" "${size}" "${MASTER}" --out "${OUT_DIR}/${name}" >/dev/null
done

echo "Wrote $(ls "${OUT_DIR}"/*.png | wc -l | tr -d ' ') PNG sizes to ${OUT_DIR}"
