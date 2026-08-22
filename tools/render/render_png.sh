#!/usr/bin/env bash
# Rasterise a rendered panel SVG (tools/render/out/<id>.svg) to a PNG the model can open and view.
# Uses headless Microsoft Edge (Chromium) so the SVG renders exactly as in a browser.
# Usage: bash tools/render/render_png.sh <id>            e.g. pfd   (defaults: all panels)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/tools/render/out"
EDGE="/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
[ -x "$EDGE" ] || { echo "Edge not found at $EDGE"; exit 1; }

png_one() {
  local id="$1"
  local svg="$OUT/$id.svg"
  [ -f "$svg" ] || { echo "!! $id: no $svg"; return 1; }
  # pull the pixel size straight off the <svg> tag
  local dims w h
  dims=$(grep -oE 'width="[0-9]+" height="[0-9]+"' "$svg" | head -1)
  w=$(echo "$dims" | grep -oE '[0-9]+' | sed -n 1p)
  h=$(echo "$dims" | grep -oE '[0-9]+' | sed -n 2p)
  # wrapper page: the SVG inline on the cockpit ground, margin-free so viewport == art size
  local html; html="$(mktemp --suffix=.html)"
  { printf '<!doctype html><meta charset="utf-8"><body style="margin:0;background:#0a0d12">'; cat "$svg"; printf '</body>'; } > "$html"
  local udd; udd="$(mktemp -d)"
  "$EDGE" --headless=new --disable-gpu --no-first-run --no-default-browser-check --hide-scrollbars \
    --user-data-dir="$(cygpath -w "$udd")" --force-device-scale-factor=2 \
    --window-size="$w,$h" --screenshot="$(cygpath -w "$OUT/$id.png")" \
    "$(cygpath -w "$html")" >/dev/null 2>&1 || true
  rm -rf "$udd"; rm -f "$html"
  if [ -f "$OUT/$id.png" ]; then echo "ok $id -> out/$id.png (${w}x${h} @2x)"; else echo "!! $id: PNG not produced"; return 1; fi
}

if [ $# -ge 1 ] && [ "$1" != "all" ]; then
  png_one "$1"
else
  for svg in "$OUT"/*.svg; do png_one "$(basename "$svg" .svg)"; done
fi
