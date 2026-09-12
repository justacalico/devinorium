#!/usr/bin/env bash
# Regenerate the iOS "Add to Home Screen" assets under flutter/web/icons/:
# Apple touch icons and per-device launch splash screens. iOS ignores the
# manifest for both of these and requires link tags in index.html instead.
# Requires rsvg-convert and ImageMagick (magick).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_SVG="$ROOT/icon.svg"
ICON_DIR="$ROOT/flutter/web/icons"
SPLASH_DIR="$ICON_DIR/splash"
BG="#0F172A" # matches background_color in flutter/web/manifest.json

command -v rsvg-convert >/dev/null || { echo "error: rsvg-convert is required" >&2; exit 1; }
command -v magick >/dev/null || { echo "error: ImageMagick (magick) is required" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
MASTER="$TMP_DIR/icon-1024.png"
rsvg-convert -w 1024 -h 1024 -o "$MASTER" "$ICON_SVG"

mkdir -p "$ICON_DIR" "$SPLASH_DIR"
rm -f "$SPLASH_DIR"/*.png

# Touch icons. The svg art leaves the corners transparent, so flatten onto
# the brand background; iOS would render transparent pixels as black anyway.
for size in 120 152 167 180; do
  magick "$MASTER" -background "$BG" -alpha remove -alpha off \
    -resize "${size}x${size}" -strip "$ICON_DIR/apple-touch-icon-$size.png"
done
cp "$ICON_DIR/apple-touch-icon-180.png" "$ICON_DIR/apple-touch-icon.png"

# Splash screens are picked per device via media queries in index.html, so
# the filename must stay "<pixel width>x<pixel height>" of the device screen.
make_splash() {
  local w="$1" h="$2"
  local logo=$(( (w < h ? w : h) / 3 ))
  magick -size "${w}x${h}" "xc:$BG" \
    \( "$MASTER" -resize "${logo}x${logo}" \) \
    -gravity center -composite \
    -strip "PNG8:$SPLASH_DIR/apple-splash-${w}x${h}.png"
}

# "css_width css_height dpr" per device class. iOS has no landscape launch
# images for iPhones, so only iPads get landscape variants.
IPHONES=(
  "320 568 2"   # SE 1st gen
  "375 667 2"   # SE 2nd/3rd gen, 8
  "414 736 3"   # 8 Plus
  "375 812 3"   # X/XS/11 Pro, 12/13 mini
  "414 896 2"   # XR, 11
  "414 896 3"   # XS Max, 11 Pro Max
  "390 844 3"   # 12/13/14
  "428 926 3"   # 12/13/14 Pro Max, 14 Plus
  "393 852 3"   # 14 Pro, 15/15 Pro, 16
  "430 932 3"   # 14 Pro Max, 15 Plus/Pro Max, 16 Plus
  "402 874 3"   # 16 Pro, 17/17 Pro
  "420 912 3"   # iPhone Air
  "440 956 3"   # 16 Pro Max, 17 Pro Max
)
IPADS=(
  "768 1024 2"  # 9.7" iPads, mini 7.9"
  "810 1080 2"  # 10.2" iPads
  "834 1112 2"  # 10.5" Pro
  "834 1194 2"  # 11" Pro (LCD gens)
  "834 1210 2"  # 11" Pro M4
  "820 1180 2"  # 10.9"/11" Air, iPad A16
  "744 1133 2"  # mini 8.3"
  "1024 1366 2" # 12.9" Pro, 13" Air
  "1032 1376 2" # 13" Pro M4
)

for spec in "${IPHONES[@]}"; do
  read -r cw ch dpr <<<"$spec"
  make_splash "$((cw * dpr))" "$((ch * dpr))"
done
for spec in "${IPADS[@]}"; do
  read -r cw ch dpr <<<"$spec"
  make_splash "$((cw * dpr))" "$((ch * dpr))"
  make_splash "$((ch * dpr))" "$((cw * dpr))"
done

echo "Wrote $(find "$SPLASH_DIR" -name '*.png' | wc -l) splash screens and 5 touch icons to $ICON_DIR"
