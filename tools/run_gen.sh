#!/usr/bin/env bash
# Run tools/gen_manifest.lua headless in CraftOS-PC against the repo, writing manifest.lua back.
#
#   tools/run_gen.sh              write manifest.lua
#   tools/run_gen.sh --check      assert manifest.lua is in sync, no write
#   tools/run_gen.sh --selftest   print reference fnv1a checksums
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"
WORK="$ROOT/tests/.craftos/gen"; DATA="$WORK/data"; C0="$DATA/computer/0"
rm -rf "$WORK"; mkdir -p "$C0"
[ -d "$ROOT/tools" ] && cp -r "$ROOT/tools" "$C0"/
[ -d "$ROOT/fcs" ] && cp -r "$ROOT/fcs" "$C0"/
[ -d "$ROOT/ui" ] && cp -r "$ROOT/ui" "$C0"/
[ -d "$ROOT/launchers" ] && cp -r "$ROOT/launchers" "$C0"/
[ -f "$ROOT/easyhover2_suite.lua" ] && cp "$ROOT/easyhover2_suite.lua" "$C0"/
[ -f "$ROOT/manifest.lua" ] && cp "$ROOT/manifest.lua" "$C0"/
# Args are passed via a file rather than CraftOS-PC's own argv, so --headless stays simple.
printf '%s\n' "$@" > "$C0/gen_args.txt"
cat > "$C0/startup.lua" <<'LUA'
package.path = "/?.lua;/?/init.lua;" .. package.path
local genArgs = {}
if fs.exists("/gen_args.txt") then
  local f = fs.open("/gen_args.txt", "r")
  for line in (f.readAll() or ""):gmatch("[^\n]+") do genArgs[#genArgs + 1] = line end
  f.close()
end
local ok, err = pcall(function() shell.run("tools/gen_manifest.lua", table.unpack(genArgs)) end)
if not ok then
  local f = fs.open("/gen_result.txt", "w"); f.write("ERROR " .. tostring(err)); f.close()
end
os.shutdown()
LUA
timeout 60 "$CRAFTOS" --headless -d "$DATA" >/dev/null 2>&1 || true
[ -f "$C0/manifest.lua" ] && cp "$C0/manifest.lua" "$ROOT/manifest.lua"
if [ -f "$C0/gen_result.txt" ]; then
  cat "$C0/gen_result.txt"; echo ""
else
  echo "NO RESULT (harness did not run)"
fi
