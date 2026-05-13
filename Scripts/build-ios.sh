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
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

assert_png_has_no_alpha() {
    local png="$1"
    local has_alpha
    has_alpha=$(sips -g hasAlpha "${png}" 2>/dev/null | awk '/hasAlpha/ {print $2}')
    if [[ "${has_alpha}" != "no" ]]; then
        echo "error: ${png} has alpha channel; iOS app icons must be opaque PNGs" >&2
        exit 1
    fi
}

validate_ios_source_icons() {
    local icon_dir="${PROJECT_DIR}/Resources/Assets.xcassets/AppIcon.appiconset"

    echo "==> Validating iOS source icon PNGs"
    if [[ ! -f "${icon_dir}/icon-1024.png" ]]; then
        echo "error: ${icon_dir}/icon-1024.png is missing" >&2
        exit 1
    fi

    local icon
    while IFS= read -r -d '' icon; do
        assert_png_has_no_alpha "${icon}"
    done < <(find "${icon_dir}" -maxdepth 1 -type f -name '*.png' -print0)
    echo "    source icon PNGs are opaque"
}

validate_ios_app_bundle() {
    local app="$1"
    local plist="${app}/Info.plist"

    echo "==> Validating iOS icon metadata in ${app}"
    if [[ ! -d "${app}" ]]; then
        echo "error: app bundle missing at ${app}" >&2
        exit 1
    fi
    if [[ ! -f "${plist}" ]]; then
        echo "error: Info.plist missing at ${plist}" >&2
        exit 1
    fi

    local icon_name
    icon_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "${plist}" 2>/dev/null || true)
    if [[ "${icon_name}" != "AppIcon" ]]; then
        echo "error: ${plist} has CFBundleIconName='${icon_name:-<missing>}' (expected AppIcon)" >&2
        exit 1
    fi

    if [[ ! -f "${app}/Assets.car" ]]; then
        echo "error: ${app}/Assets.car is missing; asset catalog was not compiled into the app" >&2
        exit 1
    fi

    local iphone_icon="${app}/AppIcon60x60@2x.png"
    local ipad_icon="${app}/AppIcon76x76@2x~ipad.png"
    for icon in "${iphone_icon}" "${ipad_icon}"; do
        if [[ ! -f "${icon}" ]]; then
            echo "error: required app icon missing from bundle: ${icon}" >&2
            exit 1
        fi
    done

    local iphone_size ipad_size
    iphone_size=$(sips -g pixelWidth -g pixelHeight "${iphone_icon}" 2>/dev/null | awk '/pixel/ {print $2}' | paste -sd x -)
    ipad_size=$(sips -g pixelWidth -g pixelHeight "${ipad_icon}" 2>/dev/null | awk '/pixel/ {print $2}' | paste -sd x -)
    if [[ "${iphone_size}" != "120x120" ]]; then
        echo "error: ${iphone_icon} is ${iphone_size:-unknown}, expected 120x120" >&2
        exit 1
    fi
    if [[ "${ipad_size}" != "152x152" ]]; then
        echo "error: ${ipad_icon} is ${ipad_size:-unknown}, expected 152x152" >&2
        exit 1
    fi
    assert_png_has_no_alpha "${iphone_icon}"
    assert_png_has_no_alpha "${ipad_icon}"

    echo "    CFBundleIconName=${icon_name}; required icon PNGs are present"
}

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
    # Accept either format in the secret: raw PEM (the .p8 file's
    # contents as Apple distributes them, beginning with
    # `-----BEGIN PRIVATE KEY-----`) OR the base64-encoded version
    # of that PEM. Auto-detect by sniffing the first line.
    # Previously the script always ran `base64 -D` which produced
    # garbage bytes when the secret was already PEM, surfacing
    # cryptography's `MalformedFraming` from the inline preflight.
    if printf '%s' "${AC_API_KEY_P8_BASE64}" | head -n 1 | grep -q '^-----BEGIN'; then
        printf '%s\n' "${AC_API_KEY_P8_BASE64}" > "${AC_API_KEY_P8_PATH}"
    else
        printf '%s' "${AC_API_KEY_P8_BASE64}" | base64 -D > "${AC_API_KEY_P8_PATH}"
    fi
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
if ! grep -q "Assets.xcassets in Resources" "${PROJECT}/project.pbxproj"; then
    echo "error: generated Xcode project does not put Resources/Assets.xcassets in the Resources build phase" >&2
    exit 1
fi
validate_ios_source_icons

mkdir -p "${BUILD_DIR}"

if command -v security >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
    CERT_PEM="$(mktemp -t reolens-ios-dist-cert.XXXXXX)"
    if security find-certificate -c "Apple Distribution" -p > "${CERT_PEM}" 2>/dev/null; then
        CERT_SERIAL="$(
            openssl x509 -in "${CERT_PEM}" -noout -serial 2>/dev/null \
                | sed 's/^serial=//' \
                | tr '[:lower:]' '[:upper:]' \
                | tr -d ':'
        )"
        if [[ -n "${CERT_SERIAL}" ]]; then
            export ASC_CERT_SERIAL_NUMBER="${CERT_SERIAL}"
            echo "==> Pinning App Store profiles to Apple Distribution cert serial ${ASC_CERT_SERIAL_NUMBER}"
        fi
    fi
    rm -f "${CERT_PEM}"
fi

# xcodebuild's "automatic" signing in Xcode 26 silently ignores
# command-line CODE_SIGN_IDENTITY overrides AND defaults to creating an
# iOS App Development profile when archiving on a CI runner — which then
# fails with "Your team has no devices" because Development profiles
# require a registered device. The reliable workaround is to drop to
# manual signing and pre-create the App Store profile via the ASC API.
#
# `Scripts/asc_ensure_profile.py` does the API dance (creates the bundle
# id and profile if needed, downloads the .mobileprovision into
# ~/Library/MobileDevice/Provisioning Profiles/) and prints the profile
# name + UUID on stdout. We pass both through target-specific project
# variables so Xcode cannot accidentally reuse a stale same-name profile.
PROFILE_NAME=""
PROFILE_UUID=""
WIDGETS_PROFILE_NAME=""
WIDGETS_PROFILE_UUID=""
if [[ -n "${AC_API_KEY_ID:-}" && -n "${AC_API_KEY_P8_PATH:-}" ]]; then
    echo "==> Ensuring App Store provisioning profile via ASC API (main app)"
    export PLATFORM=IOS
    export IOS_BUNDLE_ID="${IOS_BUNDLE_ID:-com.reolens.Reolens.iOS}"
    export PROFILE_NAME="${PROFILE_NAME:-Reolens iOS App Store}"
    HELPER_OUT="$(python3 "${REPO_ROOT}/Scripts/asc_ensure_profile.py")"
    PROFILE_NAME="$(printf '%s\n' "${HELPER_OUT}" | sed -n '1p')"
    PROFILE_UUID="$(printf '%s\n' "${HELPER_OUT}" | sed -n '3p')"
    echo "    using main-app profile: ${PROFILE_NAME} (${PROFILE_UUID})"

    # 0.5.0 — the widget extension target has its own bundle id
    # (com.reolens.Reolens.iOS.Widgets) and Apple requires a
    # SEPARATE provisioning profile per bundle id. Run the helper
    # again with PLATFORM=IOS_WIDGETS so the widget extension gets
    # its own profile registered/created/installed alongside the
    # main app's. Save and restore the main-app PROFILE_NAME
    # around the call — without the restore, `set -u` downstream
    # trips on "PROFILE_NAME: unbound variable" when we read it
    # for SIGN_BUILD_SETTINGS / ExportOptions.plist.
    echo "==> Ensuring App Store provisioning profile via ASC API (widget extension)"
    SAVED_PROFILE_NAME="${PROFILE_NAME}"
    export PLATFORM=IOS_WIDGETS
    export IOS_WIDGETS_BUNDLE_ID="${IOS_WIDGETS_BUNDLE_ID:-com.reolens.Reolens.iOS.Widgets}"
    unset PROFILE_NAME
    WIDGETS_HELPER_OUT="$(python3 "${REPO_ROOT}/Scripts/asc_ensure_profile.py")"
    WIDGETS_PROFILE_NAME="$(printf '%s\n' "${WIDGETS_HELPER_OUT}" | sed -n '1p')"
    WIDGETS_PROFILE_UUID="$(printf '%s\n' "${WIDGETS_HELPER_OUT}" | sed -n '3p')"
    echo "    using widgets profile: ${WIDGETS_PROFILE_NAME} (${WIDGETS_PROFILE_UUID})"
    export PROFILE_NAME="${SAVED_PROFILE_NAME}"
    export PLATFORM=IOS
fi

echo "==> Archiving for iphoneos"
# With manual signing + an explicit profile specifier, xcodebuild has to
# use what we tell it. `-allowProvisioningUpdates` lets it download the
# matching profile if it isn't already in the keychain (it is, because
# the python script just installed it, but the flag is harmless).
SIGN_BUILD_SETTINGS=()
if [[ -n "${PROFILE_NAME}" ]]; then
    SIGN_BUILD_SETTINGS=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=Apple Distribution"
        "DEVELOPMENT_TEAM=5M9UT7VQ8Q"
        "REOLENS_IOS_APP_PROFILE_NAME=${PROFILE_NAME}"
        "REOLENS_IOS_APP_PROFILE_UUID=${PROFILE_UUID}"
    )
    # 0.5.0 — pass widget profile data through distinct variables.
    # xcodebuild does NOT support command-line build settings scoped
    # with `[target=...]`; those strings are parsed as part of the
    # value. The generated project assigns these variables to the
    # correct targets in AppiOS/project.yml instead.
    if [[ -n "${WIDGETS_PROFILE_NAME}" ]]; then
        SIGN_BUILD_SETTINGS+=(
            "REOLENS_IOS_WIDGETS_PROFILE_NAME=${WIDGETS_PROFILE_NAME}"
            "REOLENS_IOS_WIDGETS_PROFILE_UUID=${WIDGETS_PROFILE_UUID}"
        )
    fi
else
    # No API key available — fall back to whatever the project has
    # configured (automatic signing with whatever Apple ID Xcode is
    # signed in as). Useful for local archives during development.
    SIGN_BUILD_SETTINGS=("CODE_SIGN_IDENTITY=Apple Distribution")
fi

# Invoke xcodebuild via an absolute path derived from DEVELOPER_DIR, and
# export that same DEVELOPER_DIR for the xcodebuild process itself.
#
# We have to go to this length because the macos-26 CI runner image
# presets PATH so Xcode_26.5_beta_2.app's bin dir comes FIRST. That
# preset wins over $GITHUB_PATH additions, AND over xcode-select.
# Both bare `xcodebuild` and `xcrun xcodebuild` end up resolving to
# the beta's binaries — and the beta's `xcrun` then forwards back
# to the beta's `xcodebuild` even with DEVELOPER_DIR=stable. The
# beta toolchain doesn't ship the iOS device platform.
#
# An absolute path skips the entire discovery dance:
#   - bash executes the exact binary we hand it
#   - that binary uses DEVELOPER_DIR / xcode-select for SDK lookup,
#     which we've already pinned to the stable Xcode
#
# Falls back to `xcode-select -p` when DEVELOPER_DIR isn't set.
# Archive with both `-sdk iphoneos` and the generic iOS destination.
# Xcode 26.5's archive action does not infer an archive destination from
# the SDK alone, but the SDK pin keeps the selected device SDK explicit.
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}"
XCODEBUILD="${XCODE_DEVELOPER_DIR}/usr/bin/xcodebuild"
echo "==> Using xcodebuild at: ${XCODEBUILD}"
"${XCODEBUILD}" \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -archivePath "${ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    ${AC_AUTH_FLAGS[@]+"${AC_AUTH_FLAGS[@]}"} \
    "${SIGN_BUILD_SETTINGS[@]}" \
    archive

validate_ios_app_bundle "${ARCHIVE_PATH}/Products/Applications/Reolens.app"

if [[ "${MODE}" == "archive" ]]; then
    echo "==> Archive ready: ${ARCHIVE_PATH}"
    echo "Open Xcode → Window → Organizer → Distribute App to upload."
    exit 0
fi

echo "==> Writing ExportOptions.plist"
# Manual signing for export too — must match the archive step's choices,
# otherwise xcodebuild re-signs the .ipa with whatever it would have
# picked automatically (often: nothing, since automatic signing fails
# for the same reason archive does).
EXPORT_BUNDLE_ID="${IOS_BUNDLE_ID:-com.reolens.Reolens.iOS}"
EXPORT_PROFILE="${PROFILE_UUID:-${PROFILE_NAME:-Reolens iOS App Store}}"
# 0.5.0 — emit a second `<key>...</key><string>...</string>` pair
# for the widget extension target so xcodebuild's `-exportArchive`
# step signs both the main app and the widget bundle correctly.
# Without the widgets entry, xcodebuild falls back to automatic
# signing for the widget extension (which fails on CI for the same
# "no devices" reason the main app does).
WIDGETS_BUNDLE_ID="${IOS_WIDGETS_BUNDLE_ID:-com.reolens.Reolens.iOS.Widgets}"
WIDGETS_PROFILE_FOR_EXPORT="${WIDGETS_PROFILE_UUID:-${WIDGETS_PROFILE_NAME:-Reolens iOS Widgets App Store}}"
cat > "${EXPORT_OPTIONS}" <<PLIST
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
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>${EXPORT_BUNDLE_ID}</key>
        <string>${EXPORT_PROFILE}</string>
        <key>${WIDGETS_BUNDLE_ID}</key>
        <string>${WIDGETS_PROFILE_FOR_EXPORT}</string>
    </dict>
    <key>uploadSymbols</key>
    <true/>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Exporting .ipa"
# Same absolute-path rationale as the archive call above.
"${XCODEBUILD}" \
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

IPA_CHECK_DIR=$(mktemp -d)
unzip -q "${IPA}" -d "${IPA_CHECK_DIR}"
IPA_APP=$(find "${IPA_CHECK_DIR}/Payload" -maxdepth 1 -type d -name '*.app' | head -n 1)
if [[ -z "${IPA_APP}" ]]; then
    echo "error: exported IPA does not contain Payload/*.app" >&2
    rm -rf "${IPA_CHECK_DIR}"
    exit 1
fi
validate_ios_app_bundle "${IPA_APP}"
rm -rf "${IPA_CHECK_DIR}"

if [[ -z "${AC_API_KEY_ID:-}" || -z "${AC_API_ISSUER_ID:-}" || -z "${AC_API_KEY_P8_PATH:-}" ]]; then
    echo "error: set AC_API_KEY_ID, AC_API_ISSUER_ID, and AC_API_KEY_P8_BASE64 (or AC_API_KEY_P8_PATH)" >&2
    exit 1
fi

# `xcrun altool` in current Xcode ignores `--apiKeyPath` and only
# looks for the .p8 in fixed locations:
#   ~/work/$REPO/$REPO/private_keys     (CI workdir)
#   ~/private_keys
#   ~/.private_keys
#   ~/.appstoreconnect/private_keys
# The flag still parses without erroring, but altool errors with -43
# "could not be found in any of these locations" if the file isn't
# at one of those exact paths. Stage the key into the canonical
# ~/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8 location.
ALTOOL_KEY_DIR="${HOME}/.appstoreconnect/private_keys"
mkdir -p "${ALTOOL_KEY_DIR}"
ALTOOL_KEY_PATH="${ALTOOL_KEY_DIR}/AuthKey_${AC_API_KEY_ID}.p8"
cp "${AC_API_KEY_P8_PATH}" "${ALTOOL_KEY_PATH}"
chmod 600 "${ALTOOL_KEY_PATH}"
trap 'rm -f "${ALTOOL_KEY_PATH}"; rm -rf "${AC_KEY_TMPDIR}"' EXIT

echo "==> Uploading to App Store Connect (TestFlight)"
set +e
ALTOOL_OUTPUT=$(xcrun altool \
    --upload-app \
    --type ios \
    --file "${IPA}" \
    --apiKey "${AC_API_KEY_ID}" \
    --apiIssuer "${AC_API_ISSUER_ID}" 2>&1)
ALTOOL_RC=$?
set -e
printf '%s\n' "${ALTOOL_OUTPUT}"
if [[ ${ALTOOL_RC} -ne 0 ]] || printf '%s\n' "${ALTOOL_OUTPUT}" | grep -Eq 'UPLOAD FAILED|Validation failed|Failed to upload package|STATE_ERROR'; then
    echo "error: App Store Connect upload failed" >&2
    exit 1
fi

echo "==> Upload complete. TestFlight processing typically takes 10–30 minutes."
echo "Track progress at: https://appstoreconnect.apple.com/apps"
