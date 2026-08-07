-- Standalone config module for the EasyHover 2 Suite's config-extension.
-- Wraps fcs/io/hwconfig.lua and mirrors tools/calibrate.lua's atomic save.
-- USED ONLY BY THE SUITE. tools/flight.lua and tools/calibrate.lua are unchanged.
local hwconfig = require("fcs.io.hwconfig")
local M = {}

-- Read + unserialise the SAVED table (pre-merge). Never throws.
-- Returns cfg|nil, existed, err. existed=true with err set means present-but-unparseable.
function M.load(path)
  if not fs.exists(path) or fs.isDir(path) then return nil, false, nil end
  local f = fs.open(path, "r")
  if not f then return nil, true, "could not open" end
  local raw = f.readAll(); f.close()
  local cfg = textutils.unserialise(raw or "")
  if type(cfg) ~= "table" then return nil, true, "not a table" end
  return cfg, true, nil
end

-- Additive: saved values over fresh defaults (deep-merged by hwconfig).
function M.withDefaults(cfg)
  return hwconfig.merge(cfg or {}, hwconfig.defaults())
end

-- Atomic write: tmp + move (mirrors calibrate.lua's saveConfig).
function M.save(path, cfg)
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "could not open tmp" end
  f.write(textutils.serialise(cfg)); f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true, nil
end

return M
