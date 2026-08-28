local hwconfig = require("fcs.io.hwconfig")
local tuningdefaults = require("fcs.io.tuningdefaults")

local M = { FILES = { devbind = "eh2_devbind.tbl", senscal = "eh2_senscal.tbl", tuning = "eh2_tuning.tbl", fuelcal = "eh2_fuelcal.tbl" } }

function M.defaults(kind)
  local d = hwconfig.defaults()
  if kind == "devbind" then return { thrusters = d.thrusters, sensors = d.sensors, fuelRelay = d.fuelRelay } end
  if kind == "senscal" then return d.bindings end
  if kind == "tuning" then return tuningdefaults.get() end
  if kind == "fuelcal" then return { fuel = require("fcs.fueltable").default } end
  error("unknown cfg kind: " .. tostring(kind))
end

function M.merge(kind, saved)
  return hwconfig.merge(saved or {}, M.defaults(kind))
end

function M.validate(kind, cfg)
  if type(cfg) ~= "table" then return false, "not a table" end
  local req = ({ devbind = {"thrusters","sensors"}, senscal = {"signPitch","signHeading"}, tuning = {"gains","caps","feel"}, fuelcal = {"fuel"} })[kind]
  for _, k in ipairs(req or {}) do if cfg[k] == nil then return false, "missing " .. k end end
  return true
end

function M.load(kind, read)
  local body = read(M.FILES[kind])
  if body == nil then return M.merge(kind, {}), false, nil end
  local saved = textutils.unserialise(body)
  if type(saved) ~= "table" then return M.merge(kind, {}), true, "unparseable" end
  return M.merge(kind, saved), true, nil
end

function M.save(kind, cfg, write)
  return write(M.FILES[kind], textutils.serialise(cfg))
end

function M.splitLegacy(hw)
  return { devbind = { thrusters = hw.thrusters, sensors = hw.sensors, fuelRelay = hw.fuelRelay },
           senscal = hw.bindings }
end

function M.assembleHw(devbind, senscal)
  return { thrusters = devbind.thrusters, sensors = devbind.sensors, fuelRelay = devbind.fuelRelay,
           bindings = senscal }
end

return M
