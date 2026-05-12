#!/usr/bin/env bash
#
# Xcode Cloud post-clone hook.
#
# Xcode Cloud invokes this script after cloning the repo but BEFORE
# `xcodebuild -resolvePackageDependencies` runs. We need it because the
# iOS app's `.xcodeproj` is gitignored — it's generated from
# `AppiOS/project.yml` via xcodegen, exactly like every local dev
# regenerates it after a pull. Without this hook, xcodebuild fails
# immediately with:
#
#     xcodebuild: error: '/Volumes/workspace/repository/AppiOS/ReolensiOS.xcodeproj' does not exist.
#
# Location: this script lives at `AppiOS/ci_scripts/ci_post_clone.sh`,
# alongside the `.xcodeproj` Xcode Cloud is configured to build. Apple's
# convention is to search for ci_scripts in the same directory as the
# Xcode project/workspace, not at the repo root.
#
# What we do here:
#   1. Install xcodegen via Homebrew (Xcode Cloud images ship with
#      Homebrew but not xcodegen).
#   2. cd into the AppiOS directory (one level up from this script)
#      and run xcodegen, which writes the .xcodeproj Xcode Cloud
#      then expects.

set -euo pipefail

echo "==> Xcode Cloud post-clone: regenerating iOS Xcode project"

# Xcode Cloud's macOS images include Homebrew. Use it to install
# xcodegen if it isn't already on PATH (cached images may have it
# preinstalled from a previous build).
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "==> Installing xcodegen"
    brew install xcodegen
else
    echo "==> xcodegen already present: $(xcodegen --version 2>&1 || echo unknown)"
fi

# This script lives at AppiOS/ci_scripts/, so the AppiOS project
# directory (which contains project.yml) is one directory up.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "==> Project directory: ${PROJECT_DIR}"

cd "${PROJECT_DIR}"
echo "==> Running xcodegen from $(pwd)"
xcodegen generate

# Sanity check — confirm the project Xcode Cloud is about to open
# actually exists now.
if [[ ! -d "${PROJECT_DIR}/ReolensiOS.xcodeproj" ]]; then
    echo "ERROR: xcodegen ran but ReolensiOS.xcodeproj is still missing" >&2
    exit 1
fi
echo "==> ReolensiOS.xcodeproj generated successfully"
