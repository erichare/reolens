#!/usr/bin/env bash
# Overlay stock-camera scenes onto the tile regions of a raw screenshot,
# instead of blurring real camera footage.
#
# Why this exists: until 0.3.0 we used Scripts/blur-screenshot.sh to
# fuzz real camera tiles in marketing screenshots. Blurred footage
# protects privacy but leaves potential users with no real sense of
# what the app looks like in use. This script replaces those tile
# regions with the procedurally-rendered "stock camera view" PNGs from
# Scripts/make-stock-camera-views.swift — a privacy-clean alternative
# that still communicates "this is a camera viewer".
#
# Usage:
#   ./Scripts/composite-screenshot.sh \
#       docs/screenshots/raw/grid-mac.png \
#       docs/screenshots/grid-adaptive.png \
#       front-door:120,80,640,360 \
#       driveway:780,80,640,360 \
#       backyard:120,460,640,360 \
#       garage:780,460,640,360
#
# Each `slug:x,y,w,h` argument places one stock scene at the given
# region (image pixels, top-left origin). The slug must match a PNG
# filename under docs/assets/stock-cameras/ (without the .png).
#
# Stock scenes are scaled to fill (cropped if aspect ratio differs)
# so they behave like the app's `.resizeAspectFill` rendering.
#
# Requires ImageMagick:
#   brew install imagemagick
#
# To find tile coordinates: open the raw screenshot in Preview, use the
# rectangular selection tool, and read the size/position from the
# Inspector pane. Round to whole pixels.

set -euo pipefail

if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ImageMagick not installed. Install with:
    brew install imagemagick
Then re-run.
EOF
    exit 1
fi

# Use `magick` (IM7) when available, falling back to `convert` (IM6).
if command -v magick >/dev/null 2>&1; then
    IM="magick"
else
    IM="convert"
fi

if [[ $# -lt 3 ]]; then
    cat >&2 <<'EOF'
Usage: composite-screenshot.sh <input.png> <output.png> <slug:x,y,w,h> [<slug:x,y,w,h> ...]

Each placement triple is "slug:x,y,w,h" where:
  slug = stock-camera image name under docs/assets/stock-cameras/
  x,y  = top-left corner in pixels (top-left origin)
  w,h  = target tile width and height in pixels

Example:
  composite-screenshot.sh raw.png out.png \
      front-door:120,80,640,360 \
      driveway:780,80,640,360

Available slugs:
EOF
    if [[ -d docs/assets/stock-cameras ]]; then
        for f in docs/assets/stock-cameras/*.png; do
            echo "  $(basename "$f" .png)" >&2
        done
    fi
    exit 1
fi

IN="$1"; shift
OUT="$1"; shift

if [[ ! -f "$IN" ]]; then
    echo "Input not found: $IN" >&2
    exit 1
fi

STOCK_DIR="$(cd "$(dirname "$0")/.." && pwd)/docs/assets/stock-cameras"
if [[ ! -d "$STOCK_DIR" ]]; then
    echo "Stock dir not found: $STOCK_DIR" >&2
    echo "Run ./Scripts/make-stock-camera-views.swift first." >&2
    exit 1
fi

# Build the composite command incrementally. Each placement becomes
# a `( stock -resize x^ -gravity center -extent WxH ) -geometry +X+Y -composite`
# segment so the stock image is scaled to fill the target region and
# cropped to exact dimensions (matches .resizeAspectFill semantics).

ARGS=("$IN")
for placement in "$@"; do
    if [[ "$placement" != *:* ]]; then
        echo "Bad placement (missing colon): $placement" >&2
        exit 1
    fi
    slug="${placement%%:*}"
    coords="${placement#*:}"
    IFS=',' read -r x y w h <<< "$coords"
    if [[ -z "$x" || -z "$y" || -z "$w" || -z "$h" ]]; then
        echo "Bad placement (need x,y,w,h): $placement" >&2
        exit 1
    fi
    stock_path="$STOCK_DIR/$slug.png"
    if [[ ! -f "$stock_path" ]]; then
        echo "Stock image not found: $stock_path" >&2
        exit 1
    fi
    # Aspect-fill: resize so the SHORT side covers, then center-crop to WxH.
    ARGS+=(
        "(" "$stock_path"
            "-resize" "${w}x${h}^"
            "-gravity" "center"
            "-extent" "${w}x${h}"
        ")"
        "-geometry" "+${x}+${y}"
        "-composite"
    )
done

ARGS+=("$OUT")

echo "==> $IM ${ARGS[*]}"
"$IM" "${ARGS[@]}"
echo "==> Wrote $OUT"
