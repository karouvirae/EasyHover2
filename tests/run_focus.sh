#!/usr/bin/env bash
# Focused headless runner for TDD iteration: runs ONLY the suites named in $SUITES
# (space-separated tests.* module names). No manifest sync check. NOT a replacement for
# run_headless.sh -- use that for the full gate before claiming done.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITES="${SUITES:-tests.test_backend}"
DATA="$(mktemp -d)"
COMP="$DATA/computer/0"
mkdir -p "$COMP"
for d in fcs tools ui nav beacon release launchers; do
  [ -d "$ROOT/$d" ] && cp -r "$ROOT/$d" "$COMP/"
done
cp -r "$ROOT/tests" "$COMP/"
{
  echo 'package.path = "/?.lua;/?/init.lua;" .. package.path'
  echo "local suites = { $(for s in $SUITES; do printf '"%s", ' "$s"; done) }"
  cat <<'LUA'
local t = require("tests.framework")
local loadErrs = {}
for _, s in ipairs(suites) do
  local ok, err = pcall(require, s)
  if not ok then loadErrs[#loadErrs+1] = s .. ": " .. tostring(err) end
end
local passed, summary = t.run()
local ok = passed and #loadErrs == 0
local extra = ""
if #loadErrs > 0 then
  extra = "\nSUITE LOAD FAILURES (" .. #loadErrs .. "):\n"
  for _, e in ipairs(loadErrs) do extra = extra .. "  " .. e .. "\n" end
end
local f = fs.open("/results.txt", "w"); f.write((ok and "OK\n" or "FAILED\n") .. summary .. extra); f.close()
os.shutdown()
LUA
} > "$COMP/startup.lua"
timeout 60 "/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe" --headless -d "$DATA" >/dev/null 2>&1 || true
if [ ! -f "$COMP/results.txt" ]; then echo "NO RESULTS (harness did not run)"; exit 1; fi
cat "$COMP/results.txt"
