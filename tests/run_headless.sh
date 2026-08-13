#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Manifest sync guard: fail fast if manifest.lua doesn't match what tools/gen_manifest.lua would
# generate from the current tree, so a stale, hand-edited, or forgotten-regen manifest never
# rides along as "passing". Uses the SAME generator code path as `tools/run_gen.sh` (no write).
echo "== manifest sync check =="
if ! bash "$ROOT/tools/run_gen.sh" --check; then
  echo "manifest.lua is OUT OF SYNC -- run: bash tools/run_gen.sh"
  exit 1
fi
echo ""

DATA="$(mktemp -d)"
COMP="$DATA/computer/0"
mkdir -p "$COMP"
if [ -d "$ROOT/fcs" ]; then cp -r "$ROOT/fcs" "$COMP/"; fi
if [ -d "$ROOT/tools" ]; then cp -r "$ROOT/tools" "$COMP/"; fi
if [ -d "$ROOT/ui" ]; then cp -r "$ROOT/ui" "$COMP/"; fi
if [ -d "$ROOT/release" ]; then cp -r "$ROOT/release" "$COMP/"; fi
if [ -d "$ROOT/launchers" ]; then cp -r "$ROOT/launchers" "$COMP/"; fi
if [ -f "$ROOT/easyhover2_suite.lua" ]; then cp "$ROOT/easyhover2_suite.lua" "$COMP/"; fi
if [ -f "$ROOT/easyhover2_suitex.lua" ]; then cp "$ROOT/easyhover2_suitex.lua" "$COMP/"; fi
if [ -f "$ROOT/manifest.lua" ]; then cp "$ROOT/manifest.lua" "$COMP/"; fi
if [ -f "$ROOT/manifest-dev.lua" ]; then cp "$ROOT/manifest-dev.lua" "$COMP/"; fi
cp -r "$ROOT/tests" "$COMP/"
cat > "$COMP/startup.lua" <<'LUA'
package.path = "/?.lua;/?/init.lua;" .. package.path
local suites = { "tests.test_keymap", "tests.test_hwconfig", "tests.test_smoke", "tests.test_pid", "tests.test_pwm", "tests.test_sigma_delta",
                 "tests.test_mixer", "tests.test_sim", "tests.test_integration", "tests.test_angle", "tests.test_yaw_mixer",
                 "tests.test_sim_yaw", "tests.test_heading", "tests.test_surge_mixer", "tests.test_sim_horizontal", "tests.test_translate", "tests.test_leash", "tests.test_envelope", "tests.test_oscillation", "tests.test_backend", "tests.test_backend_dropin", "tests.test_probe", "tests.test_calibration", "tests.test_calibrate", "tests.test_tuning", "tests.test_profile", "tests.test_instrument", "tests.test_loop", "tests.test_hover_test", "tests.test_scheme_heave", "tests.test_scheme_manual", "tests.test_scheme_cruise", "tests.test_level", "tests.test_pilot", "tests.test_protocol", "tests.test_telemetry", "tests.test_command", "tests.test_health", "tests.test_modem_mock", "tests.test_ui_config", "tests.test_ui_toolkit", "tests.test_ui_engine", "tests.test_ui_fuel", "tests.test_ui_detect", "tests.test_ui_panels", "tests.test_ui_monitors", "tests.test_flight", "tests.test_suite", "tests.test_suitex", "tests.test_suite_selfupdate", "tests.test_tuningdefaults", "tests.test_cfgspec", "tests.test_binddevices", "tests.test_cfgsync", "tests.test_bootloader", "tests.test_bootloaderui", "tests.test_cfgserver", "tests.test_cadence", "tests.test_nav", "tests.test_basalt_app", "tests.test_page_emc", "tests.test_page_fcs", "tests.test_page_ap", "tests.test_page_nav", "tests.test_page_config", "tests.test_bitconfig_hub", "tests.test_bitconfig_tuning", "tests.test_bitconfig_mdb", "tests.test_bitconfig_uical", "tests.test_bitconfig_senscal", "tests.test_bitconfig_dtc", "tests.test_bitconfig_fcssync", "tests.test_cockpit_assembly", "tests.test_switchbtn", "tests.test_region", "tests.test_picker", "tests.test_listpicker", "tests.test_region_emc", "tests.test_region_fcs", "tests.test_page_flight", "tests.test_fsx", "tests.test_manifest_channels", "tests.test_modes_golden", "tests.test_tuning_modes" }
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
