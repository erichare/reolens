#!/bin/bash
# Build, archive, and (optionally) upload the iOS app to TestFlight.
#
# Usage:
#   Scripts/build-ios.sh archive          # archive only (no upload)
#   Scripts/build-ios.sh upload           # archive + export IPA + upload to App Store Connect
#
# Required env when uploading:
#   AC_API_KEY_ID       — App Store Connect API key ID (e.g. ABC123XYZ)
#   AC_API_ISSUER_ID    — Issuer UUID
#   AC_API_KEY_P8_PATH  — Path to .p8 private key file
#                         OR set AC_API_KEY_P8_BASE64 to provide its base64 contents
#
# Both archive and upload assume:
#   - You have signed in to your Apple ID in Xcode (Settings → Accounts).
#   - The bundle ID `com.reolens.Reolens.iOS` exists in App Store Connect
#     (https://appstoreconnect.apple.com/apps → "+" → New App).
#   - Xcode's automatic signing has access to your team (5M9UT7VQ8Q).

set -euo pipefail

MODE="${1:-archive}"
SCHEME="ReolensiOS"
PROJECT_DIR="AppiOS"
PROJECT="${PROJECT_DIR}/ReolensiOS.xcodeproj"
BUILD_DIR="${BUILD_DIR:-build-ios}"
ARCHIVE_PATH="${BUILD_DIR}/ReolensiOS.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required (brew install xcodegen)" >&2
    exit 1
fi

# Resolve App Store Connect API key location once so both `archive` and
# `upload` modes can hand it to xcodebuild. Using the API key for
# xcodebuild's signing flags means we never have to sign in to Apple ID
# from Xcode's GUI — same authentication path works on dev laptops and
# CI runners. The .p8 key file is consumed by:
#   - `xcodebuild -authenticationKey*` for cert/profile fetch
#   - `xcrun altool --apiKeyPath` for the upload step
AC_AUTH_FLAGS=()
AC_KEY_TMPDIR=""
if [[ -n "${AC_API_KEY_P8_BASE64:-}" ]]; then
    AC_KEY_TMPDIR=$(mktemp -d)
    # `export` so the preflight python subprocess inherits it. Same
    # rationale for AC_API_KEY_ID / AC_API_ISSUER_ID below.
    export AC_API_KEY_P8_PATH="${AC_KEY_TMPDIR}/AuthKey_${AC_API_KEY_ID}.p8"
    echo "${AC_API_KEY_P8_BASE64}" | base64 -D > "${AC_API_KEY_P8_PATH}"
    trap 'rm -rf "${AC_KEY_TMPDIR}"' EXIT
fi
# Propagate to child processes regardless of how AC_API_KEY_P8_PATH was
# provided (env vs derived from AC_API_KEY_P8_BASE64 above).
[[ -n "${AC_API_KEY_ID:-}" ]] && export AC_API_KEY_ID
[[ -n "${AC_API_ISSUER_ID:-}" ]] && export AC_API_ISSUER_ID
[[ -n "${AC_API_KEY_P8_PATH:-}" ]] && export AC_API_KEY_P8_PATH
if [[ -n "${AC_API_KEY_ID:-}" && -n "${AC_API_ISSUER_ID:-}" && -n "${AC_API_KEY_P8_PATH:-}" ]]; then
    AC_AUTH_FLAGS=(
        "-authenticationKeyID" "${AC_API_KEY_ID}"
        "-authenticationKeyIssuerID" "${AC_API_ISSUER_ID}"
        "-authenticationKeyPath" "${AC_API_KEY_P8_PATH}"
    )
    echo "==> Using ASC API key ${AC_API_KEY_ID} for signing"

    # Pre-flight: hit a cheap ASC API endpoint to confirm the key is
    # valid AND has enough role to manage provisioning. xcodebuild's
    # generic "Authentication failed: bearer token..." uses the same
    # wording for "wrong API (Developer vs ASC)" and "role too low" —
    # distinguishing them here saves a 30s archive cycle.
    if command -v python3 >/dev/null 2>&1; then
        PREFLIGHT_SCRIPT=$(mktemp -t asc-preflight.py.XXXXXX)
        cat > "${PREFLIGHT_SCRIPT}" <<'PY'
import os, sys, time, urllib.request, urllib.error

key_id = os.environ["AC_API_KEY_ID"]
issuer_id = os.environ["AC_API_ISSUER_ID"]
p8_path = os.environ["AC_API_KEY_P8_PATH"]

try:
    import jwt
except ImportError:
    sys.stderr.write("    (skipping pre-flight: pip3 install pyjwt cryptography)\n")
    sys.exit(0)

with open(p8_path, "rb") as f:
    key = f.read()

token = jwt.encode(
    {"iss": issuer_id, "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
    key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"},
)

def hit(path):
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com/v1/" + path + "?limit=1",
        headers={"Authorization": "Bearer " + token},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "ignore")[:200]

apps_status, apps_err = hit("apps")
if apps_status != 200:
    sys.stderr.write("    pre-flight: /v1/apps returned %s\n" % apps_status)
    if apps_err:
        sys.stderr.write("    " + apps_err + "\n")
    sys.exit(2)

profiles_status, profiles_err = hit("profiles")
if profiles_status != 200:
    sys.stderr.write("    pre-flight: /v1/apps OK, /v1/profiles returned %s\n" % profiles_status)
    sys.stderr.write("    Key is valid but under-privileged (Admin role required).\n")
    if profiles_err:
        sys.stderr.write("    " + profiles_err + "\n")
    sys.exit(3)

print("    pre-flight: /v1/apps + /v1/profiles both OK")
PY
        set +e
        python3 "${PREFLIGHT_SCRIPT}"
        PREFLIGHT_RC=$?
        set -e
        rm -f "${PREFLIGHT_SCRIPT}"
        if [[ ${PREFLIGHT_RC} -ne 0 ]]; then
            echo "" >&2
            echo "    Likely fixes:" >&2
            echo "      - Key isn't an ASC API key. Create one at" >&2
            echo "        https://appstoreconnect.apple.com/access/api" >&2
            echo "        (NOT developer.apple.com → Keys). Role: Admin." >&2
            echo "      - Key role is below Admin. xcodebuild needs Admin" >&2
            echo "        to create/fetch provisioning profiles." >&2
            echo "      - .p8 contents are mangled. Re-download / regenerate." >&2
            exit ${PREFLIGHT_RC}
        fi
    fi
else
    echo "==> No ASC API key in env — falling back to Xcode's signed-in Apple ID"
fi

echo "==> Regenerating Xcode project from spec"
( cd "${PROJECT_DIR}" && xcodegen generate )

mkdir -p "${BUILD_DIR}"

echo "==> Archiving for generic/iOS"
# Force Apple Distribution signing for the archive. Without an explicit
# CODE_SIGN_IDENTITY, xcodebuild's automatic signing defaults to Apple
# Development — which then errors with "Your team has no devices" on a
# fresh CI runner because Development profiles require at least one
# registered device. Archive for App Store distribution doesn't need
# any devices, but we have to tell xcodebuild that explicitly.
#
# `-allowProvisioningUpdates` (already set above) lets xcodebuild
# auto-create the Apple Distribution certificate + App Store
# provisioning profile on first run using the ASC API key.
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "${ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    ${AC_AUTH_FLAGS[@]+"${AC_AUTH_FLAGS[@]}"} \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    archive

if [[ "${MODE}" == "archive" ]]; then
    echo "==> Archive ready: ${ARCHIVE_PATH}"
    echo "Open Xcode → Window → Organizer → Distribute App to upload."
    exit 0
fi

echo "==> Writing ExportOptions.plist"
cat > "${EXPORT_OPTIONS}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>5M9UT7VQ8Q</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Exporting .ipa"
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    -allowProvisioningUpdates \
    ${AC_AUTH_FLAGS[@]+"${AC_AUTH_FLAGS[@]}"}

# Find the produced .ipa (xcodebuild names it after the scheme + variant).
IPA=$(find "${EXPORT_DIR}" -maxdepth 1 -name '*.ipa' | head -n 1)
if [[ -z "${IPA}" ]]; then
    echo "error: no .ipa produced under ${EXPORT_DIR}" >&2
    exit 1
fi
echo "==> Exported: ${IPA}"

if [[ -z "${AC_API_KEY_ID:-}" || -z "${AC_API_ISSUER_ID:-}" || -z "${AC_API_KEY_P8_PATH:-}" ]]; then
    echo "error: set AC_API_KEY_ID, AC_API_ISSUER_ID, and AC_API_KEY_P8_BASE64 (or AC_API_KEY_P8_PATH)" >&2
    exit 1
fi

# `xcrun altool --upload-app` wants the key on disk under a directory it
# will find via --apiKeyPath, OR via the legacy private_keys lookup.
# Use --apiKey/--apiIssuer with --apiKeyPath for clarity.
echo "==> Uploading to App Store Connect (TestFlight)"
xcrun altool \
    --upload-app \
    --type ios \
    --file "${IPA}" \
    --apiKey "${AC_API_KEY_ID}" \
    --apiIssuer "${AC_API_ISSUER_ID}" \
    --apiKeyPath "${AC_API_KEY_P8_PATH}"

echo "==> Upload complete. TestFlight processing typically takes 10–30 minutes."
echo "Track progress at: https://appstoreconnect.apple.com/apps"
