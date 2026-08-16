local cfgspec = require("fcs.io.cfgspec")
local fsx = require("fcs.io.fsx")
local M = {}
function M.bind(config, role, name)
  if config.thrusters[role] ~= nil then config.thrusters[role] = name
  elseif config.sensors[role] ~= nil then config.sensors[role] = name
  elseif role == "fuelRelay" then config.fuelRelay = name end
  return config
end
function M.measureWrite(backend, id, n)
  local t0 = os.epoch("utc")
  for i = 1, n do backend:setThruster(id, i % 2 == 0) end
  return (os.epoch("utc") - t0) / n
end
-- Interactive UI (in-game only; not headless-tested)
local LEGACY_CONFIG_PATH = "/eh2_hw_config.tbl"
local realRead = fsx.read
local realWrite = fsx.writeAtomic

-- Load the existing device binding so a re-run edits rather than clobbers.
-- Prefers eh2_devbind.tbl; if absent AND the old combined /eh2_hw_config.tbl
-- is present, migrates the binding out of it (read-through, nothing lost).
-- Mirrors tools/binddevices.lua's loadBinding verbatim.
local function loadBinding(read)
  local cfg, existed = cfgspec.load("devbind", read)
  if not existed then
    local legacyBody = read(LEGACY_CONFIG_PATH)
    if legacyBody ~= nil then
      local legacy = textutils.unserialise(legacyBody)
      if type(legacy) == "table" then
        cfg = cfgspec.merge("devbind", cfgspec.splitLegacy(legacy).devbind)
      end
    end
  end
  return cfg
end

-- Read-only calibration lookup for the "sensors" diagnostic (branch "3"):
-- Backend:sensors() indexes self.config.bindings directly with no fallback
-- (`local c, b = self.config, self.config.bindings` then `b.someField`), so a
-- bare devbind table (no `bindings` key) would error with "attempt to index
-- nil value". This reads eh2_senscal.tbl (or its defaults) -- it never writes.
local function loadCalibration(read)
  return cfgspec.load("senscal", read)
end

local function discover(shim)
  for _, name in ipairs(shim.getNames()) do print(name .. "  [" .. tostring(shim.getType(name)) .. "]") end
end
function M.run()
  local shim = require("fcs.io.shim")
  local Backend = require("fcs.io.backend")
  local config = loadBinding(realRead)
  while true do
    print("\n== EH2 PROBE == 1 discover 2 bind 3 sensors 4 thruster 5 timing 6 roles 7 methods q quit")
    local ch = read()
    if ch == "1" then discover(shim)
    elseif ch == "2" then
      write("role (e.g. FL / gimbal / fuelRelay): "); local role = read()
      write("peripheral name: "); local name = read()
      config = M.bind(config, role, name); cfgspec.save("devbind", config, realWrite); print("bound " .. role .. " -> " .. name)
    elseif ch == "3" then
      local calibrated = { thrusters = config.thrusters, sensors = config.sensors, fuelRelay = config.fuelRelay,
        bindings = loadCalibration(realRead) }
      local b = Backend.new(shim, calibrated); b:sensors()
      for _=1,10 do local s=b:sensors()
        print(("alt %.2f v %.2f pitch %.3f roll %.3f hdg %.3f yawR %.3f sway %.2f surge %.2f gnd %s")
          :format(s.altitude,s.vSpeed,s.pitch,s.roll,s.heading,s.yawRate,s.swayVel,s.surgeVel,tostring(s.onGround)))
        sleep(0.3) end
    elseif ch == "4" then
      write("peripheral NAME (e.g. thruster_1): "); local name = read()
      local p = name ~= "" and shim.wrap(name) or nil
      if not p then print("no such peripheral: " .. tostring(name))
      elseif not p.setPower then
        print(tostring(name) .. " has no setPower. Its methods:")
        local ms = peripheral.getMethods(name)
        if ms then local s = ""; for _, m in ipairs(ms) do s = s .. m .. " " end; print(s) else print("(none)") end
      else
        p.setPower(15); sleep(0.5)
        print("thrustKN=" .. tostring(p.getCurrentThrustKN and p.getCurrentThrustKN() or "n/a"))
        p.setPower(0)
      end
    elseif ch == "5" then
      write("peripheral NAME: "); local name = read()
      local p = name ~= "" and shim.wrap(name) or nil
      if not p or not p.setPower then print("no thruster peripheral: " .. tostring(name))
      else
        local n = 40; local t0 = os.epoch("utc")
        for i = 1, n do p.setPower(i % 2 == 0 and 15 or 0) end
        p.setPower(0)
        print(("avg %.2f ms/write over %d writes"):format((os.epoch("utc") - t0) / n, n))
      end
    elseif ch == "6" then
      print("THRUSTERS: FL FR RL RR (lift) | YFL YFR YRL YRR (lateral) | MAIN (accel) | FRL FRR (front brakes)")
      print("SENSORS: altimeter gimbal navTable downOptical velFront velRear velMedial | fuelRelay")
    elseif ch == "7" then
      write("peripheral NAME: "); local name = read()
      local ms = peripheral.getMethods(name)
      if not ms then print("no such peripheral: " .. tostring(name))
      else local s = ""; for _, m in ipairs(ms) do s = s .. m .. " " end; print(s) end
    elseif ch == "q" then return end
  end
end
return M
