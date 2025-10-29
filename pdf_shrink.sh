#!/usr/bin/env bash
# pdf_shrink.sh — Target-size based B/W raster shrinking (1-bit) with test page
set -euo pipefail

usage(){ cat <<'EOF'
Usage:
  pdf_shrink.sh -i INPUT.pdf -t TARGET_SIZE [-o OUT_BASENAME] [--min-dpi N] [--max-dpi N] [--testpage N] [--margin FLOAT] [--no-conservative] [--no-ocr] [--verbose]
EOF
}

# ---------- Args ----------
INPUT=""; TARGET_HUMAN=""; OUT_BASENAME=""
MIN_DPI=80; MAX_DPI=300; TESTPAGE=1; WANT_OCR=1; VERBOSE=0
MARGIN=0.90; CONSERVATIVE=1
while (($#)); do
  case "$1" in
    -i) INPUT="$2"; shift 2;;
    -t) TARGET_HUMAN="$2"; shift 2;;
    -o) OUT_BASENAME="$2"; shift 2;;
    --min-dpi) MIN_DPI="$2"; shift 2;;
    --max-dpi) MAX_DPI="$2"; shift 2;;
    --testpage) TESTPAGE="$2"; shift 2;;
    --margin) MARGIN="$2"; shift 2;;
    --no-conservative) CONSERVATIVE=0; shift;;
    --no-ocr) WANT_OCR=0; shift;;
    --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done
[[ -z "${INPUT}" || -z "${TARGET_HUMAN}" ]] && { echo "Missing parameters."; usage; exit 1; }
[[ -f "$INPUT" ]] || { echo "Input file not found: $INPUT"; exit 1; }

# ---------- Deps ----------
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need gs
python3 - <<'PY' 2>/dev/null || { echo "Missing: Python package img2pdf (pip3 install --user img2pdf)"; exit 1; }
from PIL import Image; Image.MAX_IMAGE_PIXELS = None
import img2pdf  # test import only
PY
HAVE_OCRMYPDF=0; command -v ocrmypdf >/dev/null 2>&1 && HAVE_OCRMYPDF=1
HAVE_QPDF=0; command -v qpdf >/dev/null 2>&1 && HAVE_QPDF=1

# ---------- Helpers ----------
to_bytes(){ local s="$1"; shopt -s nocasematch
  if [[ "$s" =~ ^([0-9]+(\.[0-9]+)?)m$ ]]; then awk -v v="${BASH_REMATCH[1]}" 'BEGIN{printf "%.0f",v*1000000}'
  elif [[ "$s" =~ ^([0-9]+(\.[0-9]+)?)k$ ]]; then awk -v v="${BASH_REMATCH[1]}" 'BEGIN{printf "%.0f",v*1000}'
  elif [[ "$s" =~ ^[0-9]+$ ]]; then echo "$s"
  else echo "Invalid target size: $s" >&2; exit 1; fi; }
TARGET_BYTES=$(to_bytes "$TARGET_HUMAN")
[[ -z "${OUT_BASENAME}" ]] && OUT_BASENAME="$(basename "${INPUT%.*}")"
OUT_NO_OCR="${OUT_BASENAME}_bw.pdf"; OUT_OCR="${OUT_BASENAME}_bw_ocr.pdf"

# Platform-specific file size function
if [[ "$OSTYPE" == "darwin"* ]]; then
  fsize() { stat -f%z "$1"; }
else
  fsize() { stat -c%s "$1"; }
fi
human(){ awk -v s="$1" 'BEGIN{if(s>1e6)printf"%.1f MB",s/1e6;else if(s>1e3)printf"%.1f KB",s/1e3;else printf"%d B",s}'; }
log(){ ((VERBOSE)) && echo "$*"; }

# Page count (QPDF preferred; GS fallback with -dNOSAFER)
get_pages(){
  if (( HAVE_QPDF )); then qpdf --show-npages "$INPUT"; return; fi
  gs -q -dNOSAFER -dNODISPLAY -c "(${INPUT}) (r) file runpdfbegin pdfpagecount = quit" 2>/dev/null || echo "1"
}

# GS Box flags: Crop to CropBox (or TrimBox) to avoid oversized pages
GS_BOX_FLAGS=(-dUseCropBox)

# render a test page at given DPI and pack as 1-page PDF; return size in bytes
test_one_dpi(){
  local dpi="$1" tmpdir; tmpdir="$(mktemp -d -t bwtest.XXXXXX)"
  trap 'rm -rf "$tmpdir"' RETURN
  gs "${GS_BOX_FLAGS[@]}" -sDEVICE=pngmono -r"$dpi" -dFirstPage="$TESTPAGE" -dLastPage="$TESTPAGE" \
     -o "$tmpdir/pg-%03d.png" -f "$INPUT" >/dev/null
  python3 - "$tmpdir" <<'PY'
import os,sys,glob
from PIL import Image; Image.MAX_IMAGE_PIXELS = None
import img2pdf
d=sys.argv[1]
imgs=sorted(glob.glob(os.path.join(d,"pg-*.png")))
with open(os.path.join(d,"onepage.pdf"),"wb") as f:
    f.write(img2pdf.convert(imgs))
print(os.path.getsize(os.path.join(d,"onepage.pdf")))
PY
}

# render entire file and reassemble
raster_full(){
  local dpi="$1" out="$2" tmpdir; tmpdir="$(mktemp -d -t bwraster.XXXXXX)"
  echo "→ Rasterizing all pages as 1-bit PNG @${dpi}dpi …"
  if gs "${GS_BOX_FLAGS[@]}" -sDEVICE=pngmono -r"$dpi" -o "$tmpdir/pg-%05d.png" -dNOPAUSE -dBATCH -dQUIET -f "$INPUT" >/dev/null 2>&1; then
    echo "→ Assembling into PDF …"
  else
    echo "Error: Ghostscript failed" >&2
    return 1
  fi
  python3 - "$tmpdir" "$out" <<'PY'
import os,sys,glob
from PIL import Image; Image.MAX_IMAGE_PIXELS = None
import img2pdf
d,out=sys.argv[1],sys.argv[2]
imgs=sorted(glob.glob(os.path.join(d,"pg-*.png")))
with open(out,"wb") as f:
    f.write(img2pdf.convert(imgs))
PY
  rm -rf "$tmpdir"
}

PAGES=$(get_pages)
[[ "$PAGES" =~ ^[0-9]+$ ]] || { echo "Could not determine page count."; exit 1; }
echo "→ Target size: $(human $TARGET_BYTES)  | Pages: $PAGES  | File: $INPUT"

# DPI candidates (descending, in range; step 10)
CANDS=()
for ((c=MAX_DPI; c>=MIN_DPI; c-=10)); do
  CANDS+=("$c")
done
(( ${#CANDS[@]} )) || { echo "No DPI candidates in range ${MIN_DPI}-${MAX_DPI}."; exit 1; }

OCR_HEADROOM=0.92
BEST_DPI=""; target_now=$TARGET_BYTES
(( WANT_OCR==1 && HAVE_OCRMYPDF==1 )) && target_now=$(awk -v t=$TARGET_BYTES -v r=$OCR_HEADROOM 'BEGIN{printf "%.0f", t*r}')

# Safety: if test page at 300dpi > 160M px → hard cap to 200
# (heuristic only, avoids Pillow checks on extremely large PDF pages)
HARD_CAP_START=300; HARD_CAP_FALLBACK=200

for dpi in "${CANDS[@]}"; do
  # small safety clause
  if (( dpi==HARD_CAP_START )); then
    # we test anyway; if BombError occurs, our Python above catches it
    :
  fi
  bytes_one=$(test_one_dpi "$dpi") || true
  if [[ -z "${bytes_one:-}" || "$bytes_one" == "0" ]]; then
    # if something went wrong, try lower DPI
    continue
  fi
  est_total=$(( bytes_one * PAGES + 50000 ))
  echo "• Test DPI=${dpi} → 1 page ≈ $(human $bytes_one)  ⇒ estimated total ≈ $(human $est_total)"
  limit=$(awk -v t=$target_now -v m=$MARGIN 'BEGIN{printf "%.0f", t*m}')
  if (( est_total <= limit )); then BEST_DPI="$dpi"; break; fi
done

# conservatively "go a bit lower" (optional)
if [[ -z "$BEST_DPI" ]]; then BEST_DPI=$(( MIN_DPI )); fi
if (( CONSERVATIVE )); then
  dec=$(( BEST_DPI * 90 / 100 )); (( dec < MIN_DPI )) && dec=$MIN_DPI
  echo "→ Choosing conservatively ${dec} dpi."
  BEST_DPI=$dec
else
  echo "→ Choosing ${BEST_DPI} dpi (no conservative reduction)."
fi

echo "→ Rasterizing with ${BEST_DPI} dpi …"
raster_full "$BEST_DPI" "$OUT_NO_OCR"
sz=$(fsize "$OUT_NO_OCR"); echo "   Result (without OCR): $OUT_NO_OCR  ($(human $sz))"

if (( WANT_OCR==1 )); then
  if (( HAVE_OCRMYPDF==1 )); then
    echo "→ Creating OCR version (JBIG2, very small) …"
    ocrmypdf -O 3 --jbig2-lossy --jobs 2 "$OUT_NO_OCR" "$OUT_OCR"
    sz2=$(fsize "$OUT_OCR"); echo "   Result (with OCR):  $OUT_OCR  ($(human $sz2))"
    (( sz2 > TARGET_BYTES )) && echo "⚠️  OCR file exceeds target size – consider re-running with smaller --max-dpi."
  else
    echo "ℹ️  ocrmypdf not found → skipping OCR. Install: brew install ocrmypdf jbig2enc"
  fi
fi
echo "Done."
