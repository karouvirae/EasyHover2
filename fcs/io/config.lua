-- Standalone config module for the EasyHover 2 Suite's config-extension.
-- Wraps fcs/io/hwconfig.lua and mirrors tools/calibrate.lua's atomic save.
-- USED ONLY BY THE SUITE. tools/flight.lua and tools/calibrate.lua are unchanged.
local hwconfig = require("fcs.io.hwconfig")
local cfgspec = require("fcs.io.cfgspec")
local M = {}

-- Basename of a Suite config path -> merge kind.
function M.kindForPath(path)
  path = tostring(path or ""):gsub("\\", "/")
  local base = path:match("([^/]+)$") or path
  if base == "eh2_devbind.tbl" then return "devbind" end
  if base == "eh2_senscal.tbl" then return "senscal" end
  if base == "eh2_tuning.tbl" then return "tuning" end
  if base == "eh2_fuelcal.tbl" then return "fuelcal" end
  if base == "eh2_ui_config.tbl" then return "ui" end
  if base == "eh2_hw_config.tbl" then return "fused" end
  return "fused"
end

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

-- Additive: saved values over fresh defaults. When `path` is a split/UI file,
-- merge that kind (do not inject fused thrusters/sensors into tuning/UI).
function M.withDefaults(cfg, path)
  local kind = path and M.kindForPath(path) or "fused"
  if kind == "devbind" or kind == "senscal" or kind == "tuning" or kind == "fuelcal" then
    return cfgspec.merge(kind, cfg)
  end
  if kind == "ui" then
    return require("ui.config").withDefaults(cfg)
  end
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
