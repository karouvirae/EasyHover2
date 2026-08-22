#!/usr/bin/env bash
# Render a real EasyHover 2 Basalt panel to an SVG (and an ASCII preview) via CraftOS-PC.
# Usage: bash tools/render/render.sh <panel> <cols> <rows>   e.g. bash tools/render/render.sh pfd 36 24
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PANEL="${1:-pfd}"; W="${2:-36}"; H="${3:-24}"
OUTDIR="${EH2_RENDER_OUT:-$ROOT/tools/render/out}"
mkdir -p "$OUTDIR"

DATA="$(mktemp -d)"
COMP="$DATA/computer/0"
mkdir -p "$COMP"
for d in fcs ui nav beacon release tools; do
  [ -d "$ROOT/$d" ] && cp -r "$ROOT/$d" "$COMP/"
done

cat > "$COMP/startup.lua" <<LUA
package.path = "/?.lua;/?/init.lua;" .. package.path
_G.EH2_RENDER_PANEL = "$PANEL"
_G.EH2_RENDER_W = $W
_G.EH2_RENDER_H = $H
require("tools.render.render_panel")
LUA

timeout 60 "/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe" --headless -d "$DATA" >/dev/null 2>&1 || true

if [ ! -f "$COMP/render_out.txt" ]; then echo "NO OUTPUT (render did not run)"; exit 1; fi
cp "$COMP/render_out.txt" "$OUTDIR/${PANEL}.txt"
node "$ROOT/tools/render/grid_to_svg.mjs" "$OUTDIR/${PANEL}.txt" "$OUTDIR/${PANEL}.svg"
echo "==> $OUTDIR/${PANEL}.svg"
