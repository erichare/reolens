#!/usr/bin/env bash
# Build Reolens as a proper .app bundle and sign it.
#
# Required on macOS 14+ because raw SwiftPM binaries can't request Local Network
# Privacy and get -1009 ("offline") errors on any LAN connection.
#
# Signing identity is selected by env vars; ad-hoc is the default so local
# development still works without an Apple Developer account:
#
#     SIGNING_IDENTITY="Developer ID Application: Eric Hare (TEAM12345)"
#     TEAM_ID="TEAM12345"
#
# When SIGNING_IDENTITY is unset (or set to "-"), ad-hoc signing is used
# (the same behavior as before — no Gatekeeper acceptance, but launches
# fine on the developer's machine).
#
# Usage:
#     ./Scripts/build-app.sh [-c <debug|release>]      build only
#     ./Scripts/build-app.sh run                       build + launch
#     ./Scripts/build-app.sh -c release run            release build + launch

set -euo pipefail

CONFIG="debug"
DO_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c) CONFIG="$2"; shift 2 ;;
        run) DO_RUN=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${REPO_ROOT}/Reolens.app"
INFO_PLIST="${REPO_ROOT}/App/Info.plist"
ENTITLEMENTS="${REPO_ROOT}/App/Reolens.entitlements"
ICON_SRC="${REPO_ROOT}/Resources/AppIcon.icns"

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
# `codesign --timestamp` requires Apple's timestamp server, which fails on
# offline CI machines / dev machines with no network. We only request it
# when signing with a real Developer ID — ad-hoc signing always skips it.
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    TIMESTAMP_FLAG="--timestamp=none"
    SIGN_LABEL="ad-hoc"
else
    TIMESTAMP_FLAG="--timestamp"
    SIGN_LABEL="${SIGNING_IDENTITY}"
fi

cd "${REPO_ROOT}"

# Build the icon if it's missing. The .icns is generated from the
# checked-in master PNG (Resources/icon-master.png) by Scripts/build-icns.sh,
# which uses only Apple-shipped tools (sips + iconutil).
if [[ ! -f "${ICON_SRC}" ]]; then
    echo "==> Building app icon (Resources/AppIcon.icns)"
    "${REPO_ROOT}/Scripts/build-icns.sh"
fi

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="${REPO_ROOT}/.build/${CONFIG}/Reolens"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "Binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "${APP_DIR}/Contents/Frameworks"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/Reolens"
cp "${INFO_PLIST}" "${APP_DIR}/Contents/Info.plist"
cp "${ICON_SRC}"   "${APP_DIR}/Contents/Resources/AppIcon.icns"

# Embed Sparkle.framework. The SwiftPM artifact cache stores the resolved
# XCFramework under .build/artifacts/. We pick the macOS slice
# (`macos-arm64_x86_64`) and copy its `Sparkle.framework` into
# Contents/Frameworks/. The framework's own internal layout (XPC services,
# Autoupdate helper, embedded Info.plist) is preserved as-is.
SPARKLE_XCFW=$(find "${REPO_ROOT}/.build/artifacts" -type d -name 'Sparkle.xcframework' | head -n 1 || true)
if [[ -z "${SPARKLE_XCFW}" ]]; then
    echo "Sparkle.xcframework not found in .build/artifacts. Did `swift build` resolve dependencies?" >&2
    exit 1
fi
SPARKLE_FRAMEWORK="${SPARKLE_XCFW}/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "${SPARKLE_FRAMEWORK}" ]]; then
    # Fallback: glob for any macos-* slice (Sparkle has used slightly
    # different naming across releases).
    SPARKLE_FRAMEWORK=$(find "${SPARKLE_XCFW}" -type d -name 'Sparkle.framework' -path '*macos*' | head -n 1 || true)
fi
if [[ -z "${SPARKLE_FRAMEWORK}" || ! -d "${SPARKLE_FRAMEWORK}" ]]; then
    echo "macOS Sparkle.framework not found inside ${SPARKLE_XCFW}" >&2
    exit 1
fi

echo "==> Embedding Sparkle.framework from ${SPARKLE_FRAMEWORK#${REPO_ROOT}/}"
# `cp -R` preserves the framework's internal symlinks (Versions/B → Current).
cp -R "${SPARKLE_FRAMEWORK}" "${APP_DIR}/Contents/Frameworks/"

# SwiftPM's linker only adds @loader_path and the toolchain rpath to the
# main binary; it doesn't know the .app layout. Inject the conventional
# `@executable_path/../Frameworks` rpath so dyld finds the embedded
# Sparkle.framework at runtime. Idempotent: if the rpath is already
# present, install_name_tool prints a warning we suppress.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP_DIR}/Contents/MacOS/Reolens" 2>/dev/null || true

# Sign every nested bundle inside Sparkle.framework before signing the
# outer framework. Apple's codesign requires inside-out signing — XPC
# services first, helpers next, framework last, app last. `--deep` would
# do this for us but is deprecated; iterating explicitly is the
# forward-compatible path.
sign_one() {
    local target="$1"
    codesign --force \
        --sign "${SIGNING_IDENTITY}" \
        --options runtime \
        ${TIMESTAMP_FLAG} \
        "${target}" >/dev/null
}

SPARKLE_IN_APP="${APP_DIR}/Contents/Frameworks/Sparkle.framework"
# Sign every Mach-O helper Sparkle ships inside the framework.
while IFS= read -r helper; do
    sign_one "${helper}"
done < <(find "${SPARKLE_IN_APP}" -type f \
    \( -name 'Autoupdate' -o -name 'Updater' -o -name 'Installer' \) \
    -perm -u+x 2>/dev/null || true)
# Sign the XPC services bundled with Sparkle (Downloader, Installer).
while IFS= read -r xpc; do
    sign_one "${xpc}"
done < <(find "${SPARKLE_IN_APP}" -type d -name '*.xpc' 2>/dev/null || true)
# Sign the framework itself (no entitlements — frameworks don't carry them).
sign_one "${SPARKLE_IN_APP}"

echo "==> Signing app with: ${SIGN_LABEL}"
codesign --force \
    --sign "${SIGNING_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    --options runtime \
    ${TIMESTAMP_FLAG} \
    "${APP_DIR}" 2>&1 | sed 's/^/    /'

echo "==> Done: ${APP_DIR}"

if [[ "${DO_RUN}" -eq 1 ]]; then
    echo "==> Launching"
    open "${APP_DIR}"
fi
