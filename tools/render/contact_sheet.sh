#!/usr/bin/env bash
# Build the whole-cockpit contact sheet (all rendered panels as uniform thumbnails) and rasterise it
# to ONE PNG the model can open in a single Read -- the fast path for a full visual sweep after a
# UI change. Run render_all.sh first. Usage: bash tools/render/contact_sheet.sh [id ...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/tools/render/out"
EDGE="/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
[ -x "$EDGE" ] || { echo "Edge not found at $EDGE"; exit 1; }

# contact_sheet.mjs writes the HTML and prints "<W> <H>" on stdout (progress goes to stderr).
dims=$(node "$ROOT/tools/render/contact_sheet.mjs" "$@")
w=$(echo "$dims" | awk '{print $1}')
h=$(echo "$dims" | awk '{print $2}')

udd="$(mktemp -d)"
"$EDGE" --headless=new --disable-gpu --no-first-run --no-default-browser-check --hide-scrollbars \
  --user-data-dir="$(cygpath -w "$udd")" --force-device-scale-factor=1 \
  --window-size="$w,$h" --screenshot="$(cygpath -w "$OUT/contact_sheet.png")" \
  "$(cygpath -w "$OUT/contact_sheet.html")" >/dev/null 2>&1 || true
rm -rf "$udd"

if [ -f "$OUT/contact_sheet.png" ]; then echo "ok -> out/contact_sheet.png (${w}x${h})"; else echo "!! contact_sheet.png not produced"; exit 1; fi
