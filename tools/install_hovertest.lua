-- EasyHover 2 -- hover bring-up test installer.
-- Fetches tools/hover_test.lua and its full runtime dependency set from GitHub, then writes a
-- launcher (/hovertest) that sets package.path so require resolves the modules.
-- Run on the FCS PC with:
--   wget run https://raw.githubusercontent.com/maar-10/EasyHover2/worktree-level-actuator/tools/install_hovertest.lua
-- Re-run any time to update. Safe to run repeatedly (overwrites the code files).
-- NOTE: BASE is pinned to the level-actuator TEST branch (unverified in-game). When this
-- branch merges to main after a good flight, flip BASE back to .../EasyHover2/main/ .

local BASE = "https://raw.githubusercontent.com/maar-10/EasyHover2/worktree-level-actuator/"
local FILES = {
  "tools/hover_test.lua",
  "fcs/tuning.lua",
  "fcs/bringup/profile.lua",
  "fcs/bringup/instrument.lua",
  "fcs/runtime/loop.lua",
  "fcs/schemes/level_flight.lua",
  "fcs/mixer/level_flight.lua",
  "fcs/actuate/pwm.lua",
  "fcs/actuate/sigma_delta.lua",
  "fcs/actuate/level.lua",
  "fcs/control/pid.lua",
  "fcs/control/heading.lua",
  "fcs/control/translate.lua",
  "fcs/safety/oscillation.lua",
  "fcs/envelope.lua",
  "fcs/frame.lua",
  "fcs/angle.lua",
  "fcs/io/backend.lua",
  "fcs/io/shim.lua",
  "fcs/io/hwconfig.lua",
}

if not http then
  error("HTTP API is disabled -- enable http in the CC config to fetch files.", 0)
end

local function fetch(path)
  io.write("  " .. path .. " ... ")
  local h, err = http.get(BASE .. path)
  if not h then error("\nFAILED to fetch " .. path .. ": " .. tostring(err), 0) end
  local body = h.readAll()
  h.close()
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  f.write(body)
  f.close()
  print("ok (" .. #body .. " bytes)")
end

print("EasyHover 2 hover-test installer")
print("fetching files:")
for _, p in ipairs(FILES) do fetch(p) end

local LAUNCHER = 'package.path = "/?.lua;/?/init.lua;" .. package.path\n'
              .. 'require("tools.hover_test").run()\n'
local lf = fs.open("hovertest", "w")
lf.write(LAUNCHER)
lf.close()

print("")
print("Installed. Fuel the craft, then start the hover test with:")
print("  hovertest")
