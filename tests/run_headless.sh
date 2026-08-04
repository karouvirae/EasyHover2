#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$(mktemp -d)"
COMP="$DATA/computer/0"
mkdir -p "$COMP"
if [ -d "$ROOT/fcs" ]; then cp -r "$ROOT/fcs" "$COMP/"; fi
cp -r "$ROOT/tests" "$COMP/"
cat > "$COMP/startup.lua" <<'LUA'
package.path = "/?.lua;/?/init.lua;" .. package.path
local suites = { "tests.test_smoke", "tests.test_pid", "tests.test_pwm",
                 "tests.test_mixer", "tests.test_sim", "tests.test_integration", "tests.test_angle", "tests.test_yaw_mixer",
                 "tests.test_sim_yaw" }
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
timeout 60 "/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe" --headless -d "$DATA" >/dev/null 2>&1 || true
if [ ! -f "$COMP/results.txt" ]; then echo "NO RESULTS (harness did not run)"; exit 1; fi
cat "$COMP/results.txt"
grep -q '^OK' "$COMP/results.txt"
