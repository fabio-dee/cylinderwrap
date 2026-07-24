#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# make-demo-candles.sh — generate synthetic "candle product photos" for testing.
#
# These stand in for the client's 17 real product shots so the pipeline can be
# proven end-to-end before any real assets exist. Each render is a cylinder with
# physically-plausible wrap-around shading, an elliptical top rim (camera above
# the rim => "pitch"), a wax pool, a wick and a contact shadow — i.e. exactly the
# cues cylinderwrap.sh has to read back out of a photo.
#
# Variation across the set (width, height, vertical position, rim ellipse ratio,
# wax colour, background) is deliberate: the auto-detection gets tested against a
# spread, not one lucky frame.
#
# Usage: ./make-demo-candles.sh [outdir] [count]
# ------------------------------------------------------------------------------
set -euo pipefail

OUTDIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/photos}"
COUNT="${2:-17}"
MAGICK="${MAGICK:-magick}"

mkdir -p "$OUTDIR"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/democandle.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# name canvasW canvasH bodyW bodyH centreX topY rimRatio waxColour bgColour
variants=(
  "candle-01 900 1200 470 620 450 300 0.150 #efe6d6 #f6f1ea"
  "candle-02 900 1200 520 520 450 340 0.185 #e7d9c3 #f2efe6"
  "candle-03 900 1200 410 700 450 250 0.120 #f3ece0 #efe9e0"
  "candle-04 1000 1000 560 480 500 260 0.200 #dfd3bd #faf7f2"
  "candle-05 900 1200 480 640 430 290 0.160 #e9dcc6 #f4eee5"
  "candle-06 900 1200 440 580 470 330 0.145 #f1e8d8 #eee7dc"
  "candle-07 1000 1200 600 560 500 320 0.205 #e3d5bd #f7f3ec"
  "candle-08 900 1200 400 660 450 270 0.125 #ece2cd #f1ebe1"
  "candle-09 900 1100 500 540 460 300 0.175 #f0e7d5 #f5f0e8"
  "candle-10 900 1200 460 620 440 310 0.155 #e6d8c0 #f3ede3"
  "candle-11 1000 1200 540 600 520 290 0.170 #f2eade #f8f4ed"
  "candle-12 900 1200 430 700 450 240 0.130 #eadfc8 #efe8de"
  "candle-13 900 1000 510 470 450 280 0.195 #e8dbc5 #f6f2ea"
  "candle-14 900 1200 470 600 460 320 0.150 #f1e9db #f2ece2"
  "candle-15 1000 1200 580 580 500 300 0.190 #e0d2ba #f9f5ee"
  "candle-16 900 1200 450 650 440 265 0.140 #ede4d1 #f0eae0"
  "candle-17 900 1200 490 560 470 350 0.165 #e5d7bf #f5efe6"
)

render_one() {
  local name=$1 cw=$2 ch=$3 bw=$4 bh=$5 cx=$6 topy=$7 rim=$8 wax=$9 bg=${10}
  local out="$OUTDIR/$name.jpg"

  local r=$((bw / 2))
  local re boty x0 x1 wickh
  re=$(awk -v r="$r" -v k="$rim" 'BEGIN{printf "%d", r*k}')
  boty=$((topy + bh))
  x0=$((cx - r)); x1=$((cx + r))
  wickh=$((re + 22))

  # 1. Cylindrical shading: brightness ~ cos(theta - lightAngle) where the screen
  #    x maps to theta by x = r*sin(theta). One row, computed once, then stretched.
  #    The body layer is taller than the barrel (bh + 2*re) so the elliptical caps
  #    inherit the same shading instead of falling outside it.
  local bhf=$((bh + 2 * re))
  "$MAGICK" -size "${bw}x1" xc: \
    -fx "xd=(i+0.5-w/2)/(w/2); th=asin(max(-1,min(1,xd))); min(1,0.34+0.74*max(0,cos(th+0.5)))" \
    -scale "${bw}x${bhf}!" "$TMP/hshade.png"

  # 2. Wax colour as the BASE (a grayscale base would swallow the tint), then the
  #    cylindrical profile and a slight vertical falloff multiplied over it.
  "$MAGICK" -size "${bw}x${bhf}" xc:"$wax" \
    "$TMP/hshade.png" -compose Multiply -composite \
    \( -size "${bw}x${bhf}" gradient:"#ffffff-#cfc8ba" \) -compose Multiply -composite \
    "$TMP/body.png"

  # 3. Cylinder silhouette: rectangle + elliptical caps (camera above the rim).
  "$MAGICK" -size "${cw}x${ch}" xc:black -fill white \
    -draw "rectangle $x0,$topy $x1,$boty" \
    -draw "ellipse $cx,$topy $r,$re 0,360" \
    -draw "ellipse $cx,$boty $r,$re 0,360" \
    -alpha off "$TMP/sil.png"

  # 4. Body on a full-size canvas, clipped to the silhouette. The body layer is
  #    offset up by re so it spans the full silhouette including both caps.
  "$MAGICK" -size "${cw}x${ch}" xc:"$wax" \
    "$TMP/body.png" -geometry "+${x0}+$((topy - re))" -compose Over -composite \
    "$TMP/sil.png" -alpha off -compose CopyOpacity -composite \
    "$TMP/bodyc.png"

  # 5. Wax pool on top: lighter fill plus a darker inner ring for the rim edge.
  "$MAGICK" -size "${cw}x${ch}" xc:none \
    -fill "$wax" -stroke none -draw "ellipse $cx,$topy $r,$re 0,360" \
    -fill white -draw "ellipse $cx,$topy $((r - 8)),$((re * 7 / 10 + 1)) 0,360" \
    -fill "#00000010" -draw "ellipse $cx,$((topy + 2)) $((r - 4)),$((re * 8 / 10 + 1)) 0,360" \
    -blur 0x1 "$TMP/pool.png"

  # 6. Background + contact shadow.
  "$MAGICK" -size "${cw}x${ch}" gradient:"#ffffff-$bg" \
    \( -size "${cw}x${ch}" radial-gradient:"white-#ded7cd" \) -compose Multiply -composite \
    \( -size "${cw}x${ch}" xc:none -fill "#0000004d" \
       -draw "ellipse $cx,$((boty + re)) $((r + 16)),$((re + 12)) 0,360" -blur 0x16 \) \
    -compose Over -composite "$TMP/bg.png"

  # 7. Assemble, add the wick, add a little sensor grain so it reads as a photo.
  "$MAGICK" "$TMP/bg.png" \
    "$TMP/bodyc.png" -compose Over -composite \
    "$TMP/pool.png"  -compose Over -composite \
    -stroke "#3d3226" -strokewidth 5 -fill none \
    -draw "line $cx,$((topy - 1)) $((cx + 4)),$((topy - wickh))" \
    +stroke \
    -seed 42 -attenuate 0.4 +noise Gaussian \
    -quality 92 "$out"

  printf '  %-11s %4sx%-5s body=%sx%s @(%s,%s) rimMinor=%s\n' \
    "$name" "$cw" "$ch" "$bw" "$bh" "$cx" "$topy" "$re"
}

echo "Rendering demo candle photos -> $OUTDIR"
i=0
for v in "${variants[@]}"; do
  i=$((i + 1))
  [ "$i" -gt "$COUNT" ] && break
  # shellcheck disable=SC2086
  render_one $v
done
echo "Done: $(find "$OUTDIR" -name '*.jpg' | wc -l | tr -d ' ') files"
