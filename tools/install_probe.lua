-- EasyHover 2 — bring-up probe installer.
-- Fetches tools/probe.lua and its dependencies from GitHub, then writes a
-- launcher (/probe) that sets package.path so `require` resolves the modules.
-- Run on the FCS PC with:
--   wget run https://raw.githubusercontent.com/maar-10/EasyHover2/main/tools/install_probe.lua
-- Re-run any time to update. Safe to run repeatedly (overwrites the code files).

local BASE = "https://raw.githubusercontent.com/maar-10/EasyHover2/main/"
local FILES = {
  "tools/probe.lua",
  "fcs/io/shim.lua",
  "fcs/io/backend.lua",
  "fcs/io/hwconfig.lua",
  "fcs/frame.lua",
}

if not http then
  error("HTTP API is disabled — enable http in the CC config to fetch files.", 0)
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

print("EasyHover 2 probe installer")
print("fetching files:")
for _, p in ipairs(FILES) do fetch(p) end

-- Launcher: fixes package.path (so require("fcs.io....") resolves from root)
-- then runs the probe UI. Kept as a separate program so `probe` just works.
local LAUNCHER = 'package.path = "/?.lua;/?/init.lua;" .. package.path\n'
              .. 'require("tools.probe").run()\n'
local lf = fs.open("probe", "w")
lf.write(LAUNCHER)
lf.close()

print("")
print("Installed. Start the bring-up probe with:")
print("  probe")
