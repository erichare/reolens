#!/usr/bin/env bash
# Build a styled DMG containing Reolens.app + drag-to-Applications shortcut.
#
# Prefers `create-dmg` (brew install create-dmg) for a polished result with
# custom window size, icon positions, and an optional background. Falls
# back to plain `hdiutil` if `create-dmg` isn't installed, so the script
# stays usable on a stock macOS box.
#
# Outputs: dist/build/Reolens-<version>.dmg
#
# The version comes from CFBundleShortVersionString in App/Info.plist —
# single source of truth, no manual bumps anywhere else.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${REPO_ROOT}/Reolens.app"
DIST_DIR="${REPO_ROOT}/dist/build"
INFO_PLIST="${APP_DIR}/Contents/Info.plist"

if [[ ! -d "${APP_DIR}" ]]; then
    echo "Reolens.app not found — run Scripts/build-app.sh first" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${INFO_PLIST}")
DMG_PATH="${DIST_DIR}/Reolens-${VERSION}.dmg"
DMG_STABLE="${DIST_DIR}/Reolens.dmg"  # version-less alias used by reolens.io's permalink

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}" "${DMG_STABLE}"

if command -v create-dmg >/dev/null 2>&1; then
    echo "==> Building DMG with create-dmg"
    # create-dmg returns non-zero on the "code-signing not yet supported"
    # warning even when the DMG is produced fine; tolerate it.
    create-dmg \
        --volname "Reolens ${VERSION}" \
        --window-pos 200 120 \
        --window-size 600 380 \
        --icon-size 96 \
        --icon "Reolens.app" 160 180 \
        --hide-extension "Reolens.app" \
        --app-drop-link 440 180 \
        --no-internet-enable \
        "${DMG_PATH}" \
        "${APP_DIR}" || true
    if [[ ! -f "${DMG_PATH}" ]]; then
        echo "create-dmg failed to produce ${DMG_PATH}" >&2
        exit 1
    fi
else
    echo "==> create-dmg not installed; falling back to hdiutil"
    STAGE_DIR="$(mktemp -d)"
    cp -R "${APP_DIR}" "${STAGE_DIR}/"
    # Symlink to /Applications so the user can drag the app over.
    ln -s /Applications "${STAGE_DIR}/Applications"
    hdiutil create \
        -volname "Reolens ${VERSION}" \
        -srcfolder "${STAGE_DIR}" \
        -ov -format UDZO \
        "${DMG_PATH}"
    rm -rf "${STAGE_DIR}"
fi

# Sign the DMG itself (Apple recommends this for notarization). The
# SIGNING_IDENTITY env var is the same one build-app.sh consumes; if it's
# unset or "-", we skip the codesign step (ad-hoc DMG signing isn't a
# thing — Gatekeeper would reject the DMG anyway).
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [[ "${SIGNING_IDENTITY}" != "-" ]]; then
    echo "==> Signing DMG with ${SIGNING_IDENTITY}"
    codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"
fi

# Stable filename so reolens.io's "Download" button can permalink to it
# via https://github.com/erichare/reolens/releases/latest/download/Reolens.dmg
cp "${DMG_PATH}" "${DMG_STABLE}"

echo "==> DMG: ${DMG_PATH}"
echo "==> Alias: ${DMG_STABLE}"

# Emit a sha256 so the Homebrew cask can pin to it.
shasum -a 256 "${DMG_PATH}" | tee "${DMG_PATH}.sha256"
