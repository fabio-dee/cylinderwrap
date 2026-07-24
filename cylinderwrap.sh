#!/usr/bin/env bash
# ==============================================================================
#  cylinderwrap.sh — batch-render JSON label copy onto cylindrical product photos
#                  using Fred Weinhaus' cylinderize.sh
#
#  What this does that hand-tuning does not:
#
#    1. MEASURES each photo. The candle's barrel edges, rim-ellipse minor axis
#       and taper are read straight out of the image, so -r / -p / -n are
#       derived from the actual product, not guessed per file.
#    2. SOLVES for pitch. Instead of eyeballing -p, it renders, measures the
#       arc bulge of the result, and iterates (secant) until the label's curve
#       matches the curve of the candle's own rim to within a pixel.
#    3. PRESERVES type proportions. The flat label canvas is sized so that the
#       glyphs come out unstretched at the centre of the cylinder, where the eye
#       actually reads them (Hc = l*Wc / (r*arc)).
#    4. EMITS THE PARAMETERS. Every derived value is written to params.json and
#       to a runnable commands.sh, so the numbers can be reviewed, hand-edited
#       and re-run without this script in the loop.
#
#  Usage:
#     ./cylinderwrap.sh --config project.json
#     ./cylinderwrap.sh --config project.json --only candle-03
#     ./cylinderwrap.sh --config project.json --calibrate     # geometry overlays
#     ./cylinderwrap.sh --config project.json --params-only   # no pixels, just numbers
#
#  Requires: bash 3.2+, ImageMagick 6.9+ or 7.x, jq, awk. cylinderize.sh is
#  located via --cylinderize, $CYLINDERIZE, or ./vendor/cylinderize.sh.
#
#  NOTE ON LICENSING: cylinderize.sh is Fred Weinhaus' work and is free for
#  NON-COMMERCIAL use only. Commercial use requires a licence from him
#  (fmw at alink dot net). This wrapper does not grant you that licence, and
#  deliberately does not redistribute his script.
# ==============================================================================
set -euo pipefail

VERSION="1.0.0"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------ arguments
CONFIG=""
ONLY=""
CALIBRATE=0
PARAMS_ONLY=0
VERBOSE=0
CYL="${CYLINDERIZE:-$SELF_DIR/vendor/cylinderize.sh}"
JQ_MAP=""

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config)      CONFIG="$2"; shift 2 ;;
    -o|--only)        ONLY="$2"; shift 2 ;;
    --cylinderize)    CYL="$2"; shift 2 ;;
    --jq)             JQ_MAP="$2"; shift 2 ;;
    --calibrate)      CALIBRATE=1; shift ;;
    --params-only)    PARAMS_ONLY=1; shift ;;
    -v|--verbose)     VERBOSE=1; shift ;;
    -h|--help)        usage 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage 1 ;;
  esac
done

# ------------------------------------------------------------------ utilities
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[ -t 1 ] || { c_red=""; c_grn=""; c_yel=""; c_dim=""; c_off=""; }

die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
warn() { printf '%swarn:%s  %s\n' "$c_yel" "$c_off" "$*" >&2; }
info() { printf '%s\n' "$*"; }
dbg()  { [ "$VERBOSE" -eq 1 ] && printf '%s      %s%s\n' "$c_dim" "$*" "$c_off" >&2 || true; }

# float helpers — awk everywhere, so no bc/locale surprises.
# The parentheses are load-bearing: inside printf, awk reads a bare `>` as an
# output redirection, so `printf "%f", a > b ? x : y` is a syntax error.
f()  { awk "BEGIN{printf \"%.4f\", ($1)}"; }      # float
fi_() { awk "BEGIN{printf \"%d\", ($1)+0.5}"; }   # rounded int
fcmp() { awk "BEGIN{exit !($1)}"; }               # truthy test

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cylinderwrap.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------ preflight
command -v jq   >/dev/null 2>&1 || die "jq not found (brew install jq / apt install jq)"
command -v awk  >/dev/null 2>&1 || die "awk not found"

if command -v magick >/dev/null 2>&1; then MAGICK=magick; MONTAGE="magick montage"
elif command -v convert >/dev/null 2>&1; then MAGICK=convert; MONTAGE="montage"
else die "ImageMagick not found (no 'magick' or 'convert' on PATH)"; fi

# cylinderize.sh hardcodes the legacy `convert` binary. Modern IM7-only installs
# often ship without it, so drop a shim on PATH rather than editing Fred's script.
if ! command -v convert >/dev/null 2>&1; then
  mkdir -p "$TMP/shim"
  printf '#!/bin/sh\nexec magick "$@"\n' > "$TMP/shim/convert"
  chmod +x "$TMP/shim/convert"
  PATH="$TMP/shim:$PATH"
  dbg "installed IM7 'convert' shim"
fi

[ -n "$CONFIG" ] || die "no --config given (see project.example.json)"
[ -r "$CONFIG" ] || die "cannot read config: $CONFIG"
[ -r "$CYL" ]    || die "cylinderize.sh not found at: $CYL
       download it from http://www.fmwconcepts.com/imagemagick/cylinderize/index.php
       then pass --cylinderize /path/to/cylinderize.sh"

jq -e . "$CONFIG" >/dev/null 2>&1 || die "config is not valid JSON: $CONFIG"

CFGDIR="$(cd "$(dirname "$CONFIG")" && pwd)"
abspath() { case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$CFGDIR" "$1";; esac; }

IN_DIR="$(abspath "$(jq -r '.input_dir  // "."'    "$CONFIG")")"
OUT_DIR="$(abspath "$(jq -r '.output_dir // "out"' "$CONFIG")")"
TEXT_SRC="$(jq -r '.text_source // empty' "$CONFIG")"
[ -n "$TEXT_SRC" ] || die "config needs \"text_source\": path to the label JSON"
TEXT_SRC="$(abspath "$TEXT_SRC")"
[ -r "$TEXT_SRC" ] || die "cannot read text source: $TEXT_SRC"
[ -d "$IN_DIR" ]   || die "input_dir does not exist: $IN_DIR"

OUT_FMT="$(jq -r '.output_format // "jpg"' "$CONFIG")"
[ -z "$JQ_MAP" ] && JQ_MAP="$(jq -r '.jq // empty' "$CONFIG")"

mkdir -p "$OUT_DIR"
[ "$CALIBRATE" -eq 1 ] && mkdir -p "$OUT_DIR/calibration"

# ------------------------------------------------------ normalise the label JSON
# The client's JSON shape is not knowable in advance, so everything funnels
# through one jq expression into a canonical record:
#     { id, image, lines: [ {text, scale, ...} ], ...style overrides }
# Point --jq / .jq at whatever remap the real file needs; the default handles
# both a bare array and the common {"items": [...]} / {"products": [...]} wrappers.
DEFAULT_MAP='if type=="array" then . elif has("items") then .items
             elif has("products") then .products elif has("labels") then .labels
             else to_entries | map(.value + {image: .key}) end'
[ -n "$JQ_MAP" ] || JQ_MAP="$DEFAULT_MAP"

if ! jq -e "$JQ_MAP" "$TEXT_SRC" >/dev/null 2>&1; then
  die "the --jq expression failed against $TEXT_SRC
       expression: $JQ_MAP"
fi

jq -c --argjson defaults "$(jq -c '.defaults // {}' "$CONFIG")" \
      --argjson perimage "$(jq -c '.images   // {}' "$CONFIG")" '
  def norm_lines:
    if type == "array" then
      map(if type == "object" then . else {text: (.|tostring)} end)
    elif type == "string" then [{text: .}]
    else [] end;

  ('"$JQ_MAP"')
  | map(
      . as $item
      | (($item.image // $item.file // $item.filename // $item.photo // $item.id)
         | tostring) as $img
      | ($img | sub("\\.[A-Za-z0-9]+$"; "")) as $id
      | (($item.lines // $item.text // $item.copy) | norm_lines) as $lines
      | ($defaults * ($perimage[$id] // {}) * ($item.style // {})) as $style
      | $style + {id: $id, image: $img, lines: $lines}
    )
' "$TEXT_SRC" > "$TMP/items.json" || die "failed to normalise $TEXT_SRC"

ITEM_COUNT=$(jq 'length' "$TMP/items.json")
[ "$ITEM_COUNT" -gt 0 ] || die "no label records found in $TEXT_SRC"

# ==============================================================================
#  GEOMETRY DETECTION
#
#  Candle photos are typically a light product on a light background, so a
#  colour flood-fill silhouette is unreliable (it eats cream wax on cream paper).
#  A morphological edge map is not: the barrel's left/right boundary is a real
#  luminance step even when the colours are close. We then read the silhouette
#  as a per-row [leftmost, rightmost] extent profile, which tolerates the hollow
#  interior an edge map leaves behind.
#
#  From that profile:
#     barrel   = longest run of rows whose extents are stable  (rejects the
#                wick above and the drop shadow below)
#     r, cx    = half-width and centre of that run
#     rimMinor = how far the top rim ellipse rises above the barrel, recovered
#                from the row where the width crosses 0.866*wmax, because
#                w(y) = 2r*sqrt(1-((yA-y)/re)^2)  =>  re = 2*(yA - y_at_0.866)
#     narrow   = taper, from a least-squares fit of width against y
# ==============================================================================
detect_geometry() {
  local img="$1" thr="${2:-12}"
  local W H
  # NB: the trailing \n matters — `read` reports failure on EOF-without-newline
  # even though it assigns, and that trips `set -e`.
  read -r W H < <("$MAGICK" "$img" -format "%w %h\n" info:)

  "$MAGICK" "$img" -colorspace Gray -blur 0x1.5 \
      -morphology Edge Diamond:1 -auto-level -threshold "${thr}%" \
      "$TMP/edge.png"

  # restrict the dump to the edge bbox — halves the parse cost on typical shots
  local ebb ew eh ex ey
  ebb=$("$MAGICK" "$TMP/edge.png" -format "%@" info:)
  ew=${ebb%%x*}; ebb=${ebb#*x}; eh=${ebb%%+*}; ebb=${ebb#*+}; ex=${ebb%%+*}; ey=${ebb#*+}
  [ "${ew:-0}" -gt 0 ] 2>/dev/null || { echo "STATUS=noedges"; return 0; }

  "$MAGICK" "$TMP/edge.png" -crop "${ew}x${eh}+${ex}+${ey}" +repage -depth 8 txt:- \
  | awk -F'[,:]' -v ox="$ex" -v oy="$ey" -v W="$W" -v H="$H" '
      NR > 1 && $3 !~ /\(0\)/ {
        x = $1 + ox; y = $2 + oy
        PX[np] = x; PY[np] = y; np++            # kept for the second, windowed pass
        if (!(y in L) || x < L[y]) L[y] = x
        if (!(y in R) || x > R[y]) R[y] = x
      }
      END {
        # ---- pass 1: global extents, to locate the barrel roughly -----------
        n = 0; wmax = 0
        for (y in L) { ys[n++] = y+0; wd[y+0] = R[y] - L[y] + 1
                       if (wd[y+0] > wmax) wmax = wd[y+0] }
        if (n == 0 || wmax < 8) { print "STATUS=noedges"; exit }
        asort_simple(ys, n)
        if (!find_run(0.99 * wmax)) { print "STATUS=nobarrel"; exit }
        medL = median_edge(L, bs, be); medR = median_edge(R, bs, be)

        # ---- pass 2: re-measure inside the barrel x-window ------------------
        # A drop shadow or reflection is usually WIDER than the product, which
        # inflates those rows past the barrel width and hides the elliptical
        # caps behind them. Clipping the scan to the barrel column kills that.
        winL = medL - 3; winR = medR + 3
        delete L; delete R; delete wd
        for (i = 0; i < np; i++) {
          x = PX[i]; y = PY[i]
          if (x < winL || x > winR) continue
          if (!(y in L) || x < L[y]) L[y] = x
          if (!(y in R) || x > R[y]) R[y] = x
        }
        n = 0; wmax = 0
        for (y in L) { ys[n++] = y+0; wd[y+0] = R[y] - L[y] + 1 }
        asort_simple(ys, n)
        for (y = bs; y <= be; y++) if ((y in wd) && wd[y] > wmax) wmax = wd[y]
        if (wmax < 8) { print "STATUS=nobarrel"; exit }
        if (!find_run(0.99 * wmax)) { print "STATUS=nobarrel"; exit }
        medL = median_edge(L, bs, be); medR = median_edge(R, bs, be)

        # ---- rim ellipse, by least-squares on each cap edge ------------------
        # A point on a cap obeys  |x-cx| = r*sqrt(1 - ((y-yc)/re)^2), so with
        # t = sqrt(1 - ((x-cx)/r)^2) the relation is linear:  y = yc +/- re*t.
        # Each of the four cap edges (top-left, top-right, base-left,
        # base-right) is fitted independently and the survivors are pooled.
        # Fitting EDGES rather than row width matters: on a lit product one
        # side of a cap routinely fades into the background, which destroys the
        # width signal while leaving the other arc perfectly measurable.
        rad = (medR - medL) / 2
        cxv = (medL + medR) / 2
        span = int(0.9 * rad) + 4
        nTop = 0; reTopS = 0; ycTopS = 0
        nBot = 0; reBotS = 0; ycBotS = 0

        if (fit_side(L, bs, -1, cxv, rad, span, -1)) { reTopS += FIT_RE*FIT_N; ycTopS += FIT_YC*FIT_N; nTop += FIT_N }
        if (fit_side(R, bs, -1, cxv, rad, span,  1)) { reTopS += FIT_RE*FIT_N; ycTopS += FIT_YC*FIT_N; nTop += FIT_N }
        if (fit_side(L, be,  1, cxv, rad, span, -1)) { reBotS += FIT_RE*FIT_N; ycBotS += FIT_YC*FIT_N; nBot += FIT_N }
        if (fit_side(R, be,  1, cxv, rad, span,  1)) { reBotS += FIT_RE*FIT_N; ycBotS += FIT_YC*FIT_N; nBot += FIT_N }

        if (nTop) { reTop = reTopS/nTop; ycTop = ycTopS/nTop
                    if (reTop < 0.02*rad || reTop > 0.55*rad || dist(ycTop,bs) > 0.5*rad) nTop = 0 }
        if (nBot) { reBot = reBotS/nBot; ycBot = ycBotS/nBot
                    if (reBot < 0.02*rad || reBot > 0.55*rad || dist(ycBot,be) > 0.5*rad) nBot = 0 }

        conf = "ok"
        if (nTop && nBot)      { re = (reTop*nTop + reBot*nBot) / (nTop + nBot) }
        else if (nBot)         { re = reBot; conf = "rim_from_base" }
        else if (nTop)         { re = reTop; conf = "rim_from_top" }
        else                   { re = 0.15 * rad; conf = "rim_estimated" }

        # 0.99*wmax overshoots the true rim centre by re*sqrt(1-0.99^2); correct
        # the run endpoints with the fitted centre where we have one.
        barrelTop = nTop ? ycTop : bs - 0.141*re
        barrelBot = nBot ? ycBot : be + 0.141*re

        # ---- taper: least squares of width vs y over the middle 60% --------
        y0 = bs + int(0.2*(be-bs)); y1 = be - int(0.2*(be-bs))
        sx=0; sy=0; sxy=0; sxx=0; k=0
        for (y = y0; y <= y1; y++) if (y in wd) { sx+=y; sy+=wd[y]; sxy+=y*wd[y]; sxx+=y*y; k++ }
        slope = 0
        if (k > 4 && (k*sxx - sx*sx) != 0) slope = (k*sxy - sx*sy) / (k*sxx - sx*sx)
        if (k < 5) { narrow = 100 }
        wTop = (sy/k) + slope*(bs - (sx/k))
        wBot = (sy/k) + slope*(be - (sx/k))
        narrow = (wTop > 0) ? 100 * wBot / wTop : 100
        if (narrow > 100.5 || narrow < 70) narrow = 100      # implausible -> off
        if (narrow > 99.4 && narrow <= 100.5) narrow = 100

        printf "STATUS=ok\nCONF=%s\nIMG_W=%d\nIMG_H=%d\n", conf, W, H
        printf "CX=%d\nR=%d\nBARREL_TOP=%d\nBARREL_BOT=%d\nRIM_MINOR=%d\nNARROW=%.1f\nWMAX=%d\n",
               int((medL+medR)/2 + 0.5), int((medR-medL)/2 + 0.5),
               int(barrelTop + 0.5), int(barrelBot + 0.5), int(re + 0.5), narrow, wmax
      }
      function dist(a, b) { return (a > b) ? a - b : b - a }
      # least-squares fit of ONE cap edge; results land in the FIT_* globals.
      # side = -1 to fit a left edge, +1 for a right edge.
      function fit_side(arr, y0, dir, cxv, rad, span, side,
                        i, y, cnt, st, sy, stt, sty, dx, ratio, t, den, slope,
                        icept, tmin, tmax, res, rms, ta, ya) {
        cnt = 0; st = 0; sy = 0; stt = 0; sty = 0; tmin = 9; tmax = -9
        for (i = 1; i <= span; i++) {
          y = y0 + dir*i
          if (!(y in arr)) continue
          dx = arr[y] - cxv
          if (side < 0 && dx >= 0) continue      # a "left" sample right of centre
          if (side > 0 && dx <= 0) continue      # is the opposite arc leaking in
          if (dx < 0) dx = -dx
          ratio = dx / rad
          if (ratio > 0.995 || ratio < 0.30) continue    # skip the barrel + the wick
          t = sqrt(1 - ratio*ratio)
          ta[cnt] = t; ya[cnt] = y
          st += t; sy += y; stt += t*t; sty += t*y; cnt++
          if (t < tmin) tmin = t
          if (t > tmax) tmax = t
        }
        if (cnt < 4) return 0
        # a fit over a narrow slice of the cap extrapolates badly — reject it
        if (tmax - tmin < 0.35) return 0
        den = cnt*stt - st*st
        if (den == 0) return 0
        slope = (cnt*sty - st*sy) / den
        icept = (sy - slope*st) / cnt
        res = 0
        for (i = 0; i < cnt; i++) { y = ya[i] - (icept + slope*ta[i]); res += y*y }
        rms = sqrt(res / cnt)
        # a low-contrast rim leaves fragments that fit a line badly; drop those
        # rather than let them pull the estimate around
        if (rms > 2.0 && rms > 0.10 * (slope < 0 ? -slope : slope)) return 0
        FIT_RE = slope * dir
        FIT_YC = icept
        FIT_N  = cnt
        return (FIT_RE > 0)
      }
      # longest contiguous run of rows at/above a width threshold -> bs, be
      function find_run(thrw,   i, y, s, e, best, contiguous) {
        best = -1; s = -1
        for (i = 0; i < n; i++) {
          y = ys[i]
          contiguous = (i > 0 && ys[i-1] == y - 1)
          if ((y in wd) && wd[y] >= thrw) {
            if (s < 0 || !contiguous) s = y
            e = y
            if (e - s > best) { best = e - s; bs = s; be = e }
          } else s = -1
        }
        return (best >= 0)
      }
      function median_edge(arr, y0, y1,   y, m, tmp) {
        m = 0
        for (y = y0; y <= y1; y++) if (y in arr) { tmp[m] = arr[y]; m++ }
        if (m == 0) return 0
        asort_simple(tmp, m)
        return tmp[int(m/2)]
      }
      function asort_simple(arr, cnt,   i, j, t) {
        for (i = 1; i < cnt; i++) { t = arr[i]; j = i - 1
          while (j >= 0 && arr[j] > t) { arr[j+1] = arr[j]; j-- }
          arr[j+1] = t }
      }
    '
}

# ==============================================================================
#  TEXT BLOCK RENDERING
#
#  Two passes: probe every line at a reference point size to get real FreeType
#  metrics, compute the one scale factor that fits the whole block inside the
#  box, then render for real. Text always reaches ImageMagick over stdin
#  (label:@-) — inline text is parsed for %[...] escapes and a leading @ is
#  read as a FILENAME, both of which silently corrupt real-world label copy.
# ==============================================================================
PROBE_PT=100

render_text_block() {
  local item="$1" boxW="$2" boxH="$3" canvasW="$4" canvasH="$5" out="$6"
  local font color kerning gap align nlines
  font=$(jq -r '.font // empty' <<<"$item")
  color=$(jq -r '.color // "#3b3027"' <<<"$item")
  kerning=$(jq -r '.kerning // 0' <<<"$item")
  gap=$(jq -r '.line_gap // 0.28' <<<"$item")
  align=$(jq -r '.align // "center"' <<<"$item")
  nlines=$(jq '.lines | length' <<<"$item")
  [ "$nlines" -gt 0 ] || die "record has no text lines"

  [ -n "$font" ] || die "no font configured (defaults.font)"
  if [ "${font#/}" != "$font" ] || [ -e "$font" ]; then
    [ -r "$font" ] || die "font file not readable: $font"
  fi

  # ---- pass 1: probe metrics -------------------------------------------------
  local i blockW=0 blockH=0 lw lh lscale lfont lkern
  for (( i=0; i<nlines; i++ )); do
    lscale=$(jq -r ".lines[$i].scale // 1" <<<"$item")
    lfont=$(jq -r ".lines[$i].font // empty" <<<"$item"); [ -n "$lfont" ] || lfont="$font"
    lkern=$(jq -r ".lines[$i].kerning // empty" <<<"$item"); [ -n "$lkern" ] || lkern="$kerning"
    local pt; pt=$(f "$PROBE_PT * $lscale")
    local kp; kp=$(f "$lkern * $pt / 100")
    jq -j ".lines[$i].text" <<<"$item" > "$TMP/line.txt"
    if [ ! -s "$TMP/line.txt" ]; then LW[$i]=0; LH[$i]=0; continue; fi
    local metrics
    metrics=$("$MAGICK" -font "$lfont" -pointsize "$pt" -kerning "$kp" \
                -background none -fill "$color" "label:@$TMP/line.txt" \
                -format "%w %h\n" info: 2>"$TMP/fonterr") || true
    # A missing font is only a WARNING in ImageMagick — it exits 0 and silently
    # substitutes a default face. Checked explicitly so 17 images can't come out
    # in the wrong typeface without anyone noticing.
    if grep -q "unable to read font" "$TMP/fonterr" 2>/dev/null; then
        die "ImageMagick could not load the font:
         $lfont
       It only warns and substitutes a default face, so this is checked here.
       Give an absolute path to a .ttf/.otf/.ttc (this build has no fontconfig,
       so family names like \"Futura\" will not resolve)."
    fi
    [ -n "$metrics" ] || die "text probe failed for line $i: $(head -1 "$TMP/fonterr")"
    read -r lw lh <<<"$metrics"
    LW[$i]=$lw; LH[$i]=$lh
    fcmp "$lw > $blockW" && blockW=$lw
    blockH=$(f "$blockH + $lh")
    [ "$i" -lt $((nlines-1)) ] && blockH=$(f "$blockH + $gap * $pt * $lscale")
  done

  fcmp "$blockW > 0 && $blockH > 0" || die "all text lines are empty"

  # ---- one scale factor for the whole block ---------------------------------
  local k; k=$(f "($boxW/$blockW < $boxH/$blockH) ? $boxW/$blockW : $boxH/$blockH")

  # ---- pass 2: render, stack with spacers -----------------------------------
  local -a parts=()
  for (( i=0; i<nlines; i++ )); do
    [ "${LW[$i]}" = "0" ] && continue
    lscale=$(jq -r ".lines[$i].scale // 1" <<<"$item")
    lfont=$(jq -r ".lines[$i].font // empty" <<<"$item"); [ -n "$lfont" ] || lfont="$font"
    lkern=$(jq -r ".lines[$i].kerning // empty" <<<"$item"); [ -n "$lkern" ] || lkern="$kerning"
    local lcolor; lcolor=$(jq -r ".lines[$i].color // empty" <<<"$item"); [ -n "$lcolor" ] || lcolor="$color"
    local pt2 kp2
    pt2=$(fi_ "$PROBE_PT * $lscale * $k")
    [ "$pt2" -lt 1 ] && pt2=1
    kp2=$(f "$lkern * $pt2 / 100")
    jq -j ".lines[$i].text" <<<"$item" > "$TMP/line.txt"
    "$MAGICK" -font "$lfont" -pointsize "$pt2" -kerning "$kp2" \
       -background none -fill "$lcolor" "label:@$TMP/line.txt" "$TMP/l$i.png"
    parts+=( "$TMP/l$i.png" )
    if [ "$i" -lt $((nlines-1)) ]; then
      local gp; gp=$(fi_ "$gap * $PROBE_PT * $lscale * $k")
      [ "$gp" -lt 1 ] && gp=1
      "$MAGICK" -size "1x${gp}" xc:none "$TMP/g$i.png"
      parts+=( "$TMP/g$i.png" )
    fi
  done

  local grav
  case "$align" in left) grav=West ;; right) grav=East ;; *) grav=Center ;; esac
  "$MAGICK" "${parts[@]}" -background none -gravity "$grav" -append "$TMP/block.png"

  # ---- place the block on the flat label canvas ------------------------------
  "$MAGICK" -size "${canvasW}x${canvasH}" xc:none "$TMP/block.png" \
      -gravity Center -compose Over -composite "$out"
}

# ==============================================================================
#  PITCH SOLVER
#
#  The -p of cylinderize is not the camera elevation angle, and how it maps to
#  the on-screen arc depends on -e, -r and -l too. Rather than assume a mapping,
#  we measure: render, read the bbox height, and the excess over -l IS the arc
#  bulge. Secant-iterate -p until that bulge equals the bulge the candle rim
#  itself implies, re*(1 - cos(arc/2)). Converges in 2-3 renders (~0.4s each).
#
#  Everything is measured against an OPAQUE probe of the same canvas size as the
#  label, never the label itself: a label is mostly transparent, so its bounding
#  box tracks the glyphs rather than the band. Output canvas size depends only on
#  the parameters, so the probe bbox transfers to the real render exactly.
# ==============================================================================
run_cylinderize() {   # flat, out, r, l, wrap, pitch, efactor, narrow
  local flat="$1" out="$2" r="$3" l="$4" wrap="$5" pitch="$6" ef="$7" nr="$8"
  if ! bash "$CYL" -m vertical -r "$r" -l "$l" -w "$wrap" -p "$pitch" \
        -e "$ef" -n "$nr" -v background -b none -f none \
        "$flat" "$out" 2>"$TMP/cylerr"; then
    grep -v 'deprecated in IMv7' "$TMP/cylerr" >&2 || true
    die "cylinderize.sh failed (r=$r l=$l w=$wrap p=$pitch e=$ef n=$nr)"
  fi
}

bbox_of() { "$MAGICK" "$1" -format "%@" info:; }

solve_pitch() {   # flat r l wrap efactor narrow target_bulge -> pitch
  local flat="$1" r="$2" l="$3" wrap="$4" ef="$5" nr="$6" target="$7"
  local p b bb hh iter=0 prev_p="" prev_b=""

  # seed from the calibration sweep: bulge ~= 0.007 * r * pitch (at e=1)
  p=$(f "$target / (0.007 * $r * $ef)")
  fcmp "$p < 0.2" && p=0.2
  fcmp "$p > 45"  && p=45

  while [ "$iter" -lt 5 ]; do
    run_cylinderize "$flat" "$TMP/probe.png" "$r" "$l" "$wrap" "$p" "$ef" "$nr"
    bb=$(bbox_of "$TMP/probe.png"); hh=${bb#*x}; hh=${hh%%+*}
    b=$(f "$hh - $l")
    dbg "pitch solve: p=$p -> bulge=$b (target $target)"
    fcmp "($b - $target) < 1 && ($target - $b) < 1" && break
    if [ -n "$prev_p" ] && fcmp "($b - $prev_b) > 0.01 || ($prev_b - $b) > 0.01"; then
      local np; np=$(f "$p + ($target - $b) * ($p - $prev_p) / ($b - $prev_b)")   # secant
      prev_p=$p; prev_b=$b; p=$np
    else
      prev_p=$p; prev_b=$b
      p=$(f "$b > 0.05 ? $p * $target / $b : $p * 2")
    fi
    fcmp "$p < 0.1" && p=0.1
    fcmp "$p > 60"  && p=60
    iter=$((iter+1))
  done
  printf '%s' "$p"
}

# ==============================================================================
#  MAIN LOOP
# ==============================================================================
info "cylinderwrap $VERSION  ${c_dim}| $ITEM_COUNT record(s) | cylinderize: $CYL${c_off}"
info ""

PARAMS_JSON="$TMP/params_acc.json"; echo '[]' > "$PARAMS_JSON"
CMDS="$OUT_DIR/commands.sh"
{ printf '#!/usr/bin/env bash\n# Generated by cylinderwrap %s\n' "$VERSION"
  printf '# Per-image cylinderize.sh parameters, derived from each photo.\n'
  printf '# The label PNGs referenced here are written to %s/flat/\n\n' "$OUT_DIR"
  printf 'CYL="%s"\n\n' "$CYL"; } > "$CMDS"
mkdir -p "$OUT_DIR/flat"

OK=0; SKIP=0; FAIL=0
START=$SECONDS

RENDERED=()

for (( idx=0; idx<ITEM_COUNT; idx++ )); do
  # clear detection state first — a `continue` further down must not let one
  # image's geometry leak into the next
  unset G_STATUS G_CONF G_CX G_R G_BARREL_TOP G_BARREL_BOT G_RIM_MINOR G_NARROW \
        G_IMG_W G_IMG_H G_WMAX PX PY || true

  ITEM=$(jq -c ".[$idx]" "$TMP/items.json")
  ID=$(jq -r '.id' <<<"$ITEM")
  IMGNAME=$(jq -r '.image' <<<"$ITEM")

  [ -n "$ONLY" ] && [ "$ONLY" != "$ID" ] && continue

  IMG="$IN_DIR/$IMGNAME"
  if [ ! -r "$IMG" ]; then
    # tolerate a missing/!matching extension in the JSON
    CAND=$(find "$IN_DIR" -maxdepth 1 -iname "${ID}.*" 2>/dev/null | head -1)
    if [ -n "$CAND" ]; then IMG="$CAND"; else
      warn "$ID: image not found ($IMGNAME) — skipped"; SKIP=$((SKIP+1)); continue
    fi
  fi

  printf '%-14s ' "$ID"

  # ---------------------------------------------------------------- geometry
  GEO=$(detect_geometry "$IMG" "$(jq -r '.edge_threshold // 12' <<<"$ITEM")")
  eval "$(printf '%s\n' "$GEO" | grep -E '^[A-Z_]+=' | sed 's/^/G_/')" || true
  G_STATUS="${G_STATUS:-fail}"

  # explicit per-image overrides always win over detection
  for k in cx r barrel_top barrel_bot rim_minor narrow; do
    v=$(jq -r ".geometry.$k // empty" <<<"$ITEM")
    if [ -n "$v" ]; then
      case "$k" in
        cx) G_CX=$v;; r) G_R=$v;; barrel_top) G_BARREL_TOP=$v;;
        barrel_bot) G_BARREL_BOT=$v;; rim_minor) G_RIM_MINOR=$v;; narrow) G_NARROW=$v;;
      esac
      G_STATUS=ok
    fi
  done

  if [ "$G_STATUS" != "ok" ]; then
    printf '%sFAIL%s  could not find the candle (status=%s)\n' "$c_red" "$c_off" "$G_STATUS"
    printf '               add an explicit "geometry" block for "%s" in the config\n' "$ID"
    FAIL=$((FAIL+1)); continue
  fi

  # sanity envelope — better a loud failure than 17 quietly wrong renders
  BARREL_H=$(( G_BARREL_BOT - G_BARREL_TOP ))
  if fcmp "$G_R < 0.04*$G_IMG_W || $G_R > 0.48*$G_IMG_W || $BARREL_H < 0.10*$G_IMG_H"; then
    printf '%sFAIL%s  implausible geometry: r=%s barrelH=%s on %sx%s\n' \
        "$c_red" "$c_off" "$G_R" "$BARREL_H" "$G_IMG_W" "$G_IMG_H"
    FAIL=$((FAIL+1)); continue
  fi

  # ---------------------------------------------------------------- derivation
  BAND_TOP_F=$(jq -r '.band.top     // 0.30' <<<"$ITEM")
  BAND_BOT_F=$(jq -r '.band.bottom  // 0.62' <<<"$ITEM")
  BAND_W_F=$(jq -r  '.band.width    // 0.72' <<<"$ITEM")
  INSET=$(jq -r     '.text_inset    // 0.05' <<<"$ITEM")
  EFACTOR=$(jq -r   '.efactor       // 1'    <<<"$ITEM")
  QUALITY=$(jq -r   '.quality       // 1.0'  <<<"$ITEM")
  ARC_OVR=$(jq -r   '.arc_degrees   // empty' <<<"$ITEM")
  PITCH_OVR=$(jq -r '.pitch         // empty' <<<"$ITEM")
  NARROW=$(jq -r    '.narrow        // empty' <<<"$ITEM"); [ -n "$NARROW" ] || NARROW="$G_NARROW"

  # arc: the label's chord is band.width * candle width, so half-arc = asin(w)
  if [ -n "$ARC_OVR" ]; then ARC_DEG="$ARC_OVR"
  else ARC_DEG=$(f "2 * atan2($BAND_W_F, sqrt(1-$BAND_W_F*$BAND_W_F)) * 57.29577951"); fi
  fcmp "$ARC_DEG > 170" && ARC_DEG=170
  fcmp "$ARC_DEG < 10"  && ARC_DEG=10
  WRAP=$(f "$ARC_DEG / 3.6"); fcmp "$WRAP < 10" && WRAP=10
  ARC_RAD=$(f "$ARC_DEG / 57.29577951")

  # front-face reference: the rim's lowest point is re below the barrel top
  FRONT_TOP=$(( G_BARREL_TOP + G_RIM_MINOR ))
  BAND_TOP_Y=$(fi_ "$FRONT_TOP + $BAND_TOP_F * $BARREL_H")
  BAND_BOT_Y=$(fi_ "$FRONT_TOP + $BAND_BOT_F * $BARREL_H")
  L_PX=$(( BAND_BOT_Y - BAND_TOP_Y ))
  [ "$L_PX" -gt 8 ] || { printf '%sFAIL%s  band height is %spx — check band.top/bottom\n' \
      "$c_red" "$c_off" "$L_PX"; FAIL=$((FAIL+1)); continue; }

  LABEL_W=$(fi_ "2 * $G_R * sin($ARC_RAD/2)")
  DIP=$(f "$G_RIM_MINOR * (1 - cos($ARC_RAD/2))")

  # flat canvas: width ~ on-screen width so the centre resamples ~1:1;
  # height chosen so glyph proportions survive the mapping.
  CANVAS_W=$(fi_ "$LABEL_W * $QUALITY")
  CANVAS_H=$(fi_ "$L_PX * $CANVAS_W / ($G_R * $ARC_RAD)")
  [ "$CANVAS_W" -lt 32 ] && CANVAS_W=32
  [ "$CANVAS_H" -lt 16 ] && CANVAS_H=16

  BOX_W=$(fi_ "$CANVAS_W * (1 - 2*$INSET)")
  BOX_H=$(fi_ "$CANVAS_H * (1 - 2*$INSET)")

  if [ "$PARAMS_ONLY" -eq 0 ]; then
    render_text_block "$ITEM" "$BOX_W" "$BOX_H" "$CANVAS_W" "$CANVAS_H" "$OUT_DIR/flat/$ID.png"
  fi

  # ---------------------------------------------------------------- pitch
  # opaque stand-in for the label: same canvas, but a bbox that tracks the band
  [ "$PARAMS_ONLY" -eq 0 ] && "$MAGICK" -size "${CANVAS_W}x${CANVAS_H}" xc:white "$TMP/probe_flat.png"

  if [ -n "$PITCH_OVR" ]; then
    PITCH="$PITCH_OVR"
  elif [ "$PARAMS_ONLY" -eq 1 ]; then
    PITCH=$(f "$DIP / (0.007 * $G_R * $EFACTOR)")     # analytic seed only
  else
    PITCH=$(solve_pitch "$TMP/probe_flat.png" "$G_R" "$L_PX" "$WRAP" "$EFACTOR" "$NARROW" "$DIP")
  fi

  # ---------------------------------------------------------------- render
  PX=""; PY=""
  if [ "$PARAMS_ONLY" -eq 0 ]; then
    # band geometry from the probe...
    run_cylinderize "$TMP/probe_flat.png" "$TMP/probe.png" \
        "$G_R" "$L_PX" "$WRAP" "$PITCH" "$EFACTOR" "$NARROW"
    # ...pixels from the real label, at identical parameters and canvas size
    run_cylinderize "$OUT_DIR/flat/$ID.png" "$TMP/dist.png" \
        "$G_R" "$L_PX" "$WRAP" "$PITCH" "$EFACTOR" "$NARROW"

    PC=$("$MAGICK" "$TMP/probe.png" -format "%wx%h\n" info:)
    LC=$("$MAGICK" "$TMP/dist.png"  -format "%wx%h\n" info:)
    [ "$PC" = "$LC" ] || die "$ID: probe and label canvases differ ($PC vs $LC) — cannot place reliably"

    # bbox of the band within the probe canvas
    BB=$(bbox_of "$TMP/probe.png")
    BW=${BB%%x*}; RST=${BB#*x}; BH=${RST%%+*}; RST=${RST#*+}; BX=${RST%%+*}; BY=${RST#*+}
    # place the whole canvas so that the band lands where it belongs
    PX=$(fi_ "$G_CX - $BW/2 - $BX")
    PY=$(fi_ "$BAND_TOP_Y - $DIP - $BY")
    BULGE=$(f "$BH - $L_PX")
    dbg "band ${BW}x${BH} at +${BX}+${BY} in canvas $PC; bulge=$BULGE (target $DIP)"

    # ---- analytic silhouette from the measured geometry (clip guard) --------
    "$MAGICK" -size "${G_IMG_W}x${G_IMG_H}" xc:black -fill white \
      -draw "rectangle $((G_CX-G_R)),$G_BARREL_TOP $((G_CX+G_R)),$G_BARREL_BOT" \
      -draw "ellipse $G_CX,$G_BARREL_TOP $G_R,$G_RIM_MINOR 0,360" \
      -draw "ellipse $G_CX,$G_BARREL_BOT $G_R,$G_RIM_MINOR 0,360" \
      -alpha off -blur 0x1 "$TMP/sil.png"

    SHADING=$(jq -r '.shading   // 0.55' <<<"$ITEM")
    FADE=$(jq -r    '.edge_fade // 0.35' <<<"$ITEM")
    OPACITY=$(jq -r '.opacity   // 0.95' <<<"$ITEM")
    SOFT=$(jq -r    '.softness  // 0.3'  <<<"$ITEM")
    BLEND=$(jq -r   '.blend     // "over"' <<<"$ITEM")

    # label on a full-size canvas — avoids every crop-clamping edge case.
    # %+d because a negative offset must read "-5", never "+-5"; and gravity is
    # pinned because it persists across a pipeline and would silently move this.
    GEOM=$(printf '%+d%+d' "$PX" "$PY")
    "$MAGICK" -size "${G_IMG_W}x${G_IMG_H}" xc:none \
        "$TMP/dist.png" -gravity NorthWest -geometry "$GEOM" -compose Over -composite \
        "$TMP/layer.png"

    # shading: the candle's own luminance, normalised about the mean of the band
    # so the label is modulated, not globally darkened
    BAND_MEAN=$("$MAGICK" "$IMG" -colorspace Gray \
        -crop "${LABEL_W}x${L_PX}+$((G_CX-LABEL_W/2))+${BAND_TOP_Y}" +repage \
        -format "%[fx:mean]" info: 2>/dev/null || echo 0.8)
    fcmp "$BAND_MEAN < 0.05" && BAND_MEAN=0.8
    "$MAGICK" "$IMG" -colorspace Gray -blur 0x2 \
        -function Polynomial "$(f "$SHADING/$BAND_MEAN"),$(f "1-$SHADING")" \
        "$TMP/shade.png"

    # edge falloff: ink compresses and dims toward the silhouette (x^4 curve)
    "$MAGICK" -size "${G_IMG_W}x1" xc: \
        -fx "xn=(i+0.5-$G_CX)/$G_R; xn=max(-1,min(1,xn)); 1-$FADE*(xn*xn*xn*xn)" \
        -scale "${G_IMG_W}x${G_IMG_H}!" "$TMP/fade.png"

    "$MAGICK" "$TMP/layer.png" -alpha extract \
        "$TMP/fade.png" -compose Multiply -composite \
        "$TMP/sil.png"  -compose Multiply -composite \
        -evaluate multiply "$OPACITY" "$TMP/alpha.png"

    "$MAGICK" "$TMP/layer.png" -alpha off \
        "$TMP/shade.png" -compose Multiply -composite \
        "$TMP/alpha.png" -alpha off -compose CopyOpacity -composite \
        -blur "0x$SOFT" "$TMP/label_final.png"

    OUTFILE="$OUT_DIR/$ID.$OUT_FMT"
    "$MAGICK" "$IMG" "$TMP/label_final.png" -compose "$BLEND" -composite \
        -quality 94 "$OUTFILE"
    RENDERED+=( "$OUTFILE" )
  fi

  # ---------------------------------------------------------------- calibrate
  if [ "$CALIBRATE" -eq 1 ]; then
    OVFONT=$(jq -r '.font // empty' <<<"$ITEM")
    "$MAGICK" "$IMG" ${OVFONT:+-font "$OVFONT"} \
      -fill none -stroke "#00b3ff" -strokewidth 3 \
      -draw "rectangle $((G_CX-G_R)),$G_BARREL_TOP $((G_CX+G_R)),$G_BARREL_BOT" \
      -stroke "#ff2d95" \
      -draw "ellipse $G_CX,$G_BARREL_TOP $G_R,$G_RIM_MINOR 0,360" \
      -draw "ellipse $G_CX,$G_BARREL_BOT $G_R,$G_RIM_MINOR 0,360" \
      -stroke "#ffd400" -strokewidth 2 \
      -draw "rectangle $((G_CX-LABEL_W/2)),$BAND_TOP_Y $((G_CX+LABEL_W/2)),$BAND_BOT_Y" \
      -stroke none -fill "#000000a0" \
      -draw "rectangle 8,8 $((G_IMG_W-8)),108" \
      -fill white -stroke none -pointsize 22 \
      -draw "text 20,38 'r=$G_R  cx=$G_CX  rim=$G_RIM_MINOR  narrow=$NARROW'" \
      -draw "text 20,66 'arc=${ARC_DEG}deg  wrap=$WRAP  l=$L_PX  pitch=$PITCH'" \
      -draw "text 20,94 'band y=$BAND_TOP_Y..$BAND_BOT_Y  dip=$DIP  conf=$G_CONF'" \
      "$OUT_DIR/calibration/$ID.$OUT_FMT" 2>/dev/null || \
      warn "$ID: calibration overlay failed (font unavailable for -draw text)"
  fi

  # ---------------------------------------------------------------- record
  jq -n --arg id "$ID" --arg image "$IMGNAME" \
        --argjson cx "$G_CX" --argjson r "$G_R" \
        --argjson bt "$G_BARREL_TOP" --argjson bb "$G_BARREL_BOT" \
        --argjson rim "$G_RIM_MINOR" --arg conf "${G_CONF:-ok}" \
        --argjson l "$L_PX" --arg wrap "$WRAP" --arg pitch "$PITCH" \
        --arg narrow "$NARROW" --argjson ef "$EFACTOR" \
        --arg arc "$ARC_DEG" --argjson labelw "$LABEL_W" \
        --argjson cw "$CANVAS_W" --argjson chh "$CANVAS_H" \
        --arg dip "$DIP" --arg px "${PX:-}" --arg py "${PY:-}" '
    {id:$id, image:$image,
     detected: {cx:$cx, radius:$r, barrel_top:$bt, barrel_bottom:$bb,
                rim_minor:$rim, confidence:$conf},
     cylinderize: {mode:"vertical", r:$r, l:$l, w:($wrap|tonumber),
                   p:($pitch|tonumber), e:$ef, n:($narrow|tonumber),
                   v:"background", b:"none", f:"none"},
     label: {arc_degrees:($arc|tonumber), on_screen_width:$labelw,
             flat_canvas:{w:$cw, h:$chh}, arc_dip:($dip|tonumber)},
     composite: {x:$px, y:$py}}' > "$TMP/rec.json"
  jq -s '.[0] + [.[1]]' "$PARAMS_JSON" "$TMP/rec.json" > "$TMP/pa" && mv "$TMP/pa" "$PARAMS_JSON"

  { printf '# ---- %s ----\n' "$ID"
    printf '"$CYL" -m vertical -r %s -l %s -w %s -p %s -e %s -n %s \\\n' \
           "$G_R" "$L_PX" "$WRAP" "$PITCH" "$EFACTOR" "$NARROW"
    printf '      -v background -b none -f none \\\n'
    printf '      "%s/flat/%s.png" "%s/dist_%s.png"\n' "$OUT_DIR" "$ID" "$OUT_DIR" "$ID"
    if [ -n "$PX" ]; then
      printf 'magick "%s" "%s/dist_%s.png" -gravity NorthWest -geometry %s \\\n' \
             "$IMG" "$OUT_DIR" "$ID" "$(printf '%+d%+d' "$PX" "$PY")"
      printf '      -compose over -composite "%s/%s_plain.%s"\n\n' "$OUT_DIR" "$ID" "$OUT_FMT"
    else printf '\n'; fi
  } >> "$CMDS"

  if [ "$PARAMS_ONLY" -eq 1 ]; then
    printf '%sparams%s r=%-4s l=%-4s w=%-5s p=%-5s n=%-5s arc=%s°\n' \
        "$c_dim" "$c_off" "$G_R" "$L_PX" "$WRAP" "$PITCH" "$NARROW" "$ARC_DEG"
  else
    printf '%sok%s    r=%-4s l=%-4s w=%-5s p=%-5s n=%-5s  -> %s\n' \
        "$c_grn" "$c_off" "$G_R" "$L_PX" "$WRAP" "$PITCH" "$NARROW" "$(basename "$OUT_DIR/$ID.$OUT_FMT")"
  fi
  OK=$((OK+1))
  unset G_STATUS G_CONF G_CX G_R G_BARREL_TOP G_BARREL_BOT G_RIM_MINOR G_NARROW G_IMG_W G_IMG_H G_WMAX
done

cp "$PARAMS_JSON" "$OUT_DIR/params.json"
chmod +x "$CMDS"

# ------------------------------------------------------------- contact sheet
# built from the explicit render list, so a previous sheet is never fed back in
if [ "$PARAMS_ONLY" -eq 0 ] && [ "${#RENDERED[@]}" -gt 1 ]; then
  if $MONTAGE "${RENDERED[@]}" -background "#1b1b1b" \
       -tile 6x -geometry 260x340+6+6 "$OUT_DIR/contact-sheet.jpg" 2>/dev/null; then
    info ""; info "contact sheet: $OUT_DIR/contact-sheet.jpg"
  fi
fi

ELAPSED=$((SECONDS - START))
info ""
info "${c_grn}$OK ok${c_off}  ${c_yel}$SKIP skipped${c_off}  ${c_red}$FAIL failed${c_off}   ${ELAPSED}s"
info "parameters: $OUT_DIR/params.json"
info "commands:   $CMDS"
[ "$FAIL" -gt 0 ] && exit 2
exit 0
