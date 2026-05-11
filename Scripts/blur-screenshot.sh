#!/usr/bin/env bash
# Blur the camera-feed regions of a screenshot for publishing on
# reolens.io / in the README.
#
# The principle: cameras showing real footage must never ship in
# screenshots. This script applies a strong Gaussian blur to one or more
# rectangular regions of the input image, leaving the surrounding chrome
# (sidebar, toolbar, controls) untouched.
#
# Two modes:
#
#   1. Whole-image blur, useful when you just want to fuzz a single tile:
#        ./Scripts/blur-screenshot.sh in.png out.png
#
#   2. Per-region blur, when chrome should stay sharp:
#        ./Scripts/blur-screenshot.sh in.png out.png \
#            "x,y,w,h" "x,y,w,h" ...
#      Coordinates are in image pixels, top-left origin.
#
# Requires ImageMagick (`brew install imagemagick`). The Apple-shipped
# `sips` doesn't have a region-blur primitive; ImageMagick's `-region`
# is the cleanest tool for the job.
#
# Inputs are expected under docs/screenshots/raw/ (gitignored); outputs
# go to docs/screenshots/. Paths are caller-controlled so you can also
# use this for the README.

set -euo pipefail

if ! command -v convert >/dev/null 2>&1; then
    cat >&2 <<EOF
ImageMagick not installed. Install with:
    brew install imagemagick
Then re-run.
EOF
    exit 1
fi

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <input.png> <output.png> [\"x,y,w,h\" ...]" >&2
    exit 1
fi

IN="$1"; shift
OUT="$1"; shift
BLUR_RADIUS="0x18"  # sigma 18 — heavy, faces and license plates unrecognizable

if [[ $# -eq 0 ]]; then
    echo "==> Whole-image blur ${BLUR_RADIUS} → ${OUT}"
    convert "${IN}" -blur "${BLUR_RADIUS}" "${OUT}"
    exit 0
fi

# Per-region blur. ImageMagick's `-region WxH+X+Y` constrains subsequent
# operators to that rect; chain one per region.
ARGS=("${IN}")
for region in "$@"; do
    IFS=',' read -r x y w h <<< "${region}"
    ARGS+=(-region "${w}x${h}+${x}+${y}" -blur "${BLUR_RADIUS}" +region)
done
ARGS+=("${OUT}")

echo "==> Region blur (${#@} region(s)) → ${OUT}"
convert "${ARGS[@]}"
