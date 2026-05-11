#!/usr/bin/env bash
# Notarize and staple a built artifact (Reolens.app or a DMG).
#
# Reads credentials from one of two paths:
#
# 1. Keychain profile (local dev). Run once:
#        xcrun notarytool store-credentials "reolens-notary" \
#            --apple-id "you@example.com" \
#            --team-id  "TEAMID12345" \
#            --password "<app-specific-password>"
#    Then export NOTARY_PROFILE=reolens-notary.
#
# 2. App Store Connect API key (CI). Set:
#        AC_API_KEY_ID    — the key's "Key ID" from App Store Connect
#        AC_API_ISSUER_ID — the issuer UUID
#        AC_API_KEY_P8    — the path to the downloaded .p8 file
#    (Or AC_API_KEY_P8_BASE64 — base64 contents, useful for CI secrets.)
#
# Usage:
#     ./Scripts/notarize.sh path/to/Reolens.app
#     ./Scripts/notarize.sh path/to/Reolens-0.1.0.dmg
#
# On success, the artifact is stapled in place — Gatekeeper checks pass
# offline from that point on.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <Reolens.app|Reolens.dmg>" >&2
    exit 1
fi

TARGET="$1"
if [[ ! -e "${TARGET}" ]]; then
    echo "Target not found: ${TARGET}" >&2
    exit 1
fi

# Notarytool only accepts zipped .app bundles (or .dmg / .pkg directly).
# For .app, zip it first; for .dmg, submit as-is.
SUBMIT_PATH="${TARGET}"
CLEANUP_ZIP=""
case "${TARGET}" in
    *.app)
        ZIP_PATH="$(mktemp -d)/$(basename "${TARGET}" .app).zip"
        echo "==> Zipping .app for submission: ${ZIP_PATH}"
        ditto -c -k --keepParent "${TARGET}" "${ZIP_PATH}"
        SUBMIT_PATH="${ZIP_PATH}"
        CLEANUP_ZIP="${ZIP_PATH}"
        ;;
    *.dmg|*.pkg)
        ;;
    *)
        echo "Unsupported target type: ${TARGET}" >&2
        exit 1
        ;;
esac

NOTARYTOOL_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARYTOOL_ARGS+=(--keychain-profile "${NOTARY_PROFILE}")
elif [[ -n "${AC_API_KEY_ID:-}" && -n "${AC_API_ISSUER_ID:-}" ]]; then
    KEY_PATH="${AC_API_KEY_P8:-}"
    if [[ -z "${KEY_PATH}" && -n "${AC_API_KEY_P8_BASE64:-}" ]]; then
        KEY_PATH="$(mktemp)"
        # macOS base64 doesn't accept --decode; -D is the portable flag.
        printf '%s' "${AC_API_KEY_P8_BASE64}" | base64 -D > "${KEY_PATH}"
    fi
    if [[ -z "${KEY_PATH}" || ! -f "${KEY_PATH}" ]]; then
        echo "Missing AC_API_KEY_P8 (path) or AC_API_KEY_P8_BASE64 (contents)" >&2
        exit 1
    fi
    NOTARYTOOL_ARGS+=(--key "${KEY_PATH}" --key-id "${AC_API_KEY_ID}" --issuer "${AC_API_ISSUER_ID}")
else
    echo "No credentials: set NOTARY_PROFILE, or AC_API_KEY_ID/AC_API_ISSUER_ID/AC_API_KEY_P8(_BASE64)." >&2
    exit 1
fi

echo "==> Submitting to Apple notary (this can take 1–5 minutes)"
xcrun notarytool submit "${SUBMIT_PATH}" --wait "${NOTARYTOOL_ARGS[@]}"

# Staple the ticket into the actual artifact (not the zip). For .app we
# staple the .app directly; for .dmg we staple the .dmg.
case "${TARGET}" in
    *.app|*.dmg|*.pkg)
        echo "==> Stapling ticket into ${TARGET}"
        xcrun stapler staple "${TARGET}"
        echo "==> Validating staple"
        xcrun stapler validate "${TARGET}"
        ;;
esac

# Spctl assessment — confirms Gatekeeper would accept the artifact.
echo "==> Gatekeeper assessment"
case "${TARGET}" in
    *.app) spctl -a -vv -t execute "${TARGET}" || true ;;
    *.dmg) spctl -a -vv -t open --context context:primary-signature "${TARGET}" || true ;;
esac

if [[ -n "${CLEANUP_ZIP}" ]]; then
    rm -f "${CLEANUP_ZIP}"
fi

echo "==> Notarization complete: ${TARGET}"
