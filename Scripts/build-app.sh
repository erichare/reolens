#!/usr/bin/env bash
# Build Reolens as a proper .app bundle and ad-hoc sign it.
#
# Required on macOS 14+ because raw SwiftPM binaries can't request Local Network
# Privacy and get -1009 ("offline") errors on any LAN connection.
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

cd "${REPO_ROOT}"

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

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/Reolens"
cp "${INFO_PLIST}" "${APP_DIR}/Contents/Info.plist"

echo "==> Ad-hoc signing with entitlements"
codesign --force --deep --sign - \
    --entitlements "${ENTITLEMENTS}" \
    --options runtime \
    "${APP_DIR}" 2>&1 | sed 's/^/    /'

echo "==> Done: ${APP_DIR}"

if [[ "${DO_RUN}" -eq 1 ]]; then
    echo "==> Launching"
    open "${APP_DIR}"
fi
