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
ICON_SRC="${REPO_ROOT}/Resources/AppIcon.icns"

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
# `codesign --timestamp` requires Apple's timestamp server, which fails on
# offline CI machines / dev machines with no network. We only request it
# when signing with a real Developer ID — ad-hoc signing always skips it.
#
# Entitlements: production builds (Developer ID) get the full
# sandbox + iCloud + application-group entitlements from
# `Reolens.entitlements`. Ad-hoc dev builds use a slimmed-down
# `Reolens.dev.entitlements` that omits the team-bound capabilities —
# starting on macOS 26 (Tahoe), AMFI rejects sandbox-profile
# compilation when team-bound entitlements aren't backed by a
# matching provisioning profile, and launchd fails the spawn with
# "Launchd job spawn failed" (NSPOSIXErrorDomain Code=163). The dev
# entitlements file documents the trade-offs (no iCloud sync, no
# sandbox) in its own comments.
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    TIMESTAMP_FLAG="--timestamp=none"
    SIGN_LABEL="ad-hoc"
    ENTITLEMENTS="${REPO_ROOT}/App/Reolens.dev.entitlements"
else
    TIMESTAMP_FLAG="--timestamp"
    SIGN_LABEL="${SIGNING_IDENTITY}"
    ENTITLEMENTS="${REPO_ROOT}/App/Reolens.entitlements"
fi

# Decode AC_API_KEY_P8_BASE64 → AC_API_KEY_P8_PATH if only the base64
# form is set. CI provides the .p8 contents as a secret (not a file),
# so without this decode the helper-launch guard below fails silently
# and the embedded provisioning profile never lands in the .app —
# which is exactly how v0.2.1 shipped a DMG that AMFI rejected at
# launch with -413 "No matching profile found". Mirrors the same
# block in Scripts/build-ios.sh.
AC_KEY_TMPDIR=""
if [[ -z "${AC_API_KEY_P8_PATH:-}" && -n "${AC_API_KEY_P8_BASE64:-}" && -n "${AC_API_KEY_ID:-}" ]]; then
    AC_KEY_TMPDIR=$(mktemp -d)
    export AC_API_KEY_P8_PATH="${AC_KEY_TMPDIR}/AuthKey_${AC_API_KEY_ID}.p8"
    # Accept either format in the secret: raw PEM (the .p8 file's
    # contents, beginning with `-----BEGIN PRIVATE KEY-----`) OR the
    # base64-encoded version. Auto-detect on the first line so the
    # maintainer doesn't have to remember to `base64 -i` the file.
    # Mirrors the same block in Scripts/build-ios.sh.
    if printf '%s' "${AC_API_KEY_P8_BASE64}" | head -n 1 | grep -q '^-----BEGIN'; then
        printf '%s\n' "${AC_API_KEY_P8_BASE64}" > "${AC_API_KEY_P8_PATH}"
    else
        printf '%s' "${AC_API_KEY_P8_BASE64}" | base64 -D > "${AC_API_KEY_P8_PATH}"
    fi
    trap 'rm -rf "${AC_KEY_TMPDIR}"' EXIT
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

# Embed a MAC_APP_DIRECT provisioning profile when we're signing with a
# real Developer ID identity AND ASC API credentials are present. This
# is required for any "managed" entitlement that needs profile backing
# — for us, the iCloud container entitlements introduced in v0.2.0.
# Without an embedded profile, AMFI rejects launch with -413
# "No matching profile found".
#
# The python helper creates the profile via the ASC API on first run
# and downloads it into ~/Library/MobileDevice/Provisioning Profiles/.
# We then copy the latest matching .mobileprovision into the .app as
# Contents/embedded.provisionprofile *before* signing, so codesign
# binds the profile into the bundle's signature.
#
# We hard-fail (not warn) if the embed step *should* have run but
# didn't successfully produce a file — that's exactly how v0.2.1
# shipped a profile-less DMG that AMFI rejected at launch.
if [[ "${SIGNING_IDENTITY}" != "-" ]]; then
    if [[ -z "${AC_API_KEY_ID:-}" \
            || -z "${AC_API_ISSUER_ID:-}" \
            || -z "${AC_API_KEY_P8_PATH:-}" ]]; then
        echo "ERROR: signing with '${SIGNING_IDENTITY}' but ASC API key env vars are missing." >&2
        echo "       Need AC_API_KEY_ID, AC_API_ISSUER_ID, and AC_API_KEY_P8_PATH" >&2
        echo "       (or AC_API_KEY_P8_BASE64) so we can fetch + embed the" >&2
        echo "       MAC_APP_DIRECT provisioning profile before signing." >&2
        echo "       Without the embed, AMFI rejects launch with -413." >&2
        exit 1
    fi
    echo "==> Ensuring MAC_APP_DIRECT provisioning profile via ASC API"
    export PLATFORM=MAC
    export MAC_BUNDLE_ID="${MAC_BUNDLE_ID:-com.reolens.Reolens}"
    export PROFILE_NAME="${MAC_PROFILE_NAME:-Reolens macOS Developer ID}"
    # Helper prints two lines on stdout: profile name, then the
    # absolute path to the installed .mobileprovision. We use the path
    # to embed the profile into the .app bundle before signing, which
    # is what AMFI needs to validate the iCloud entitlements at launch.
    HELPER_OUT="$(python3 "${REPO_ROOT}/Scripts/asc_ensure_profile.py")"
    EMBED_PROFILE_NAME="$(printf '%s\n' "${HELPER_OUT}" | sed -n '1p')"
    EMBED_PROFILE_PATH="$(printf '%s\n' "${HELPER_OUT}" | sed -n '2p')"
    if [[ -z "${EMBED_PROFILE_PATH}" || ! -f "${EMBED_PROFILE_PATH}" ]]; then
        echo "ERROR: provisioning profile helper reported '${EMBED_PROFILE_PATH}' but the file isn't there." >&2
        echo "       Refusing to ship a Developer ID build with no embedded profile." >&2
        exit 1
    fi
    cp "${EMBED_PROFILE_PATH}" "${APP_DIR}/Contents/embedded.provisionprofile"
    echo "    embedded: ${EMBED_PROFILE_PATH##*/} (profile: ${EMBED_PROFILE_NAME})"
fi

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
