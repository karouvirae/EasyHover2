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
                 "tests.test_mixer", "tests.test_sim", "tests.test_integration" }
local t = require("tests.framework")
for _, s in ipairs(suites) do pcall(require, s) end
local ok, summary = t.run()
local f = fs.open("/results.txt", "w"); f.write((ok and "OK\n" or "FAILED\n") .. summary); f.close()
os.shutdown()
LUA
timeout 60 "/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe" --headless -d "$DATA" >/dev/null 2>&1 || true
if [ ! -f "$COMP/results.txt" ]; then echo "NO RESULTS (harness did not run)"; exit 1; fi
cat "$COMP/results.txt"
grep -q '^OK' "$COMP/results.txt"
