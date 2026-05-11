#!/usr/bin/env bash
# Slice Resources/icon-master.png into a macOS .icns bundle.
#
# Produces Resources/AppIcon.icns, embedding the canonical macOS icon
# size ladder (16, 32, 64, 128, 256, 512, 1024 px — each at 1x and 2x).
# The build-app.sh script copies this file into Reolens.app/Contents/Resources.
#
# Usage:
#     ./Scripts/build-icns.sh
#
# Dependencies: only the Apple-supplied `sips` and `iconutil`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="${REPO_ROOT}/Resources/icon-master.png"
OUT_ICNS="${REPO_ROOT}/Resources/AppIcon.icns"
ICONSET="${REPO_ROOT}/Resources/AppIcon.iconset"

if [[ ! -f "${MASTER}" ]]; then
    echo "Master icon missing at ${MASTER}" >&2
    echo "Run: swift Scripts/make-icon.swift" >&2
    exit 1
fi

rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"

# Apple's `.iconset` naming convention is strict: each filename encodes
# the logical size and a `@2x` suffix for Retina variants.
emit() {
    local px="$1"
    local name="$2"
    sips -z "${px}" "${px}" "${MASTER}" --out "${ICONSET}/${name}" >/dev/null
}

emit 16    icon_16x16.png
emit 32    icon_16x16@2x.png
emit 32    icon_32x32.png
emit 64    icon_32x32@2x.png
emit 128   icon_128x128.png
emit 256   icon_128x128@2x.png
emit 256   icon_256x256.png
emit 512   icon_256x256@2x.png
emit 512   icon_512x512.png
emit 1024  icon_512x512@2x.png

iconutil -c icns "${ICONSET}" -o "${OUT_ICNS}"
rm -rf "${ICONSET}"

echo "wrote ${OUT_ICNS}"
