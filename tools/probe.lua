local hwconfig = require("fcs.io.hwconfig")
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
local CONFIG_PATH = "/eh2_hw_config.tbl"
local function loadConfig()
  local saved
  if fs.exists(CONFIG_PATH) then local f=fs.open(CONFIG_PATH,"r"); saved=textutils.unserialise(f.readAll() or ""); f.close() end
  return hwconfig.merge(saved or {}, hwconfig.defaults())
end
local function saveConfig(c) local f=fs.open(CONFIG_PATH,"w"); f.write(textutils.serialise(c)); f.close() end
local function discover(shim)
  for _, name in ipairs(shim.getNames()) do print(name .. "  [" .. tostring(shim.getType(name)) .. "]") end
end
function M.run()
  local shim = require("fcs.io.shim")
  local Backend = require("fcs.io.backend")
  local config = loadConfig()
  while true do
    print("\n== EH2 PROBE ==  1 discover  2 bind  3 sensors  4 thruster  5 timing  q quit")
    local ch = read()
    if ch == "1" then discover(shim)
    elseif ch == "2" then
      write("role (e.g. FL / gimbal / fuelRelay): "); local role = read()
      write("peripheral name: "); local name = read()
      config = M.bind(config, role, name); saveConfig(config); print("bound " .. role .. " -> " .. name)
    elseif ch == "3" then
      local b = Backend.new(shim, config); b:sensors()
      for _=1,10 do local s=b:sensors()
        print(("alt %.2f v %.2f pitch %.3f roll %.3f hdg %.3f yawR %.3f sway %.2f surge %.2f gnd %s")
          :format(s.altitude,s.vSpeed,s.pitch,s.roll,s.heading,s.yawRate,s.swayVel,s.surgeVel,tostring(s.onGround)))
        sleep(0.3) end
    elseif ch == "4" then
      write("thruster id: "); local id = read()
      local b = Backend.new(shim, config)
      b:setThruster(id, true); sleep(0.5)
      local p = shim.wrap(config.thrusters[id]); print("thrustKN=" .. tostring(p and p.getCurrentThrustKN and p.getCurrentThrustKN()))
      b:setThruster(id, false)
    elseif ch == "5" then
      write("thruster id: "); local id = read()
      local b = Backend.new(shim, config)
      print(("avg %.2f ms/write over 40 writes"):format(M.measureWrite(b, id, 40)))
    elseif ch == "q" then return end
  end
end
return M
