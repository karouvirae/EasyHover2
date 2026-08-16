package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local SS = require("ui.basalt.senssource")

-- an injected read(path)->body: serialise fake config files
local function reader(files)
  return function(path) return files[path] end
end

t.test("resolve OFF returns no cal/sensors", function()
  local r = SS.resolve({ source = "OFF" }, reader({}))
  t.eq(r.source, "OFF"); t.eq(r.cal, nil)
end)

t.test("resolve FCS loads senscal + devbind from local files", function()
  local files = {
    ["eh2_senscal.tbl"] = textutils.serialise({ signPitch = -1, signHeading = 1, gimbalScale = 1 }),
    ["eh2_devbind.tbl"] = textutils.serialise({ thrusters = {}, sensors = { gimbal = "gimbal_5", velMedial = "vel_2" } }),
  }
  local r = SS.resolve({ source = "FCS" }, reader(files))
  t.eq(r.source, "FCS")
  t.eq(r.cal.signPitch, -1, "cal from senscal")
  t.eq(r.sensors.gimbal, "gimbal_5", "names from devbind")
  t.eq(r.calExisted, true); t.eq(r.bindExisted, true)
end)

t.test("resolve SELF uses config.sens.self for the cal", function()
  local files = { ["eh2_devbind.tbl"] = textutils.serialise({ thrusters = {}, sensors = { gimbal = "g", velMedial = "v" } }) }
  local r = SS.resolve({ source = "SELF", self = { signPitch = 1, signVelMedial = -1 } }, reader(files))
  t.eq(r.cal.signVelMedial, -1); t.eq(r.calExisted, true)
end)

t.test("readAttitude wraps names, reads, applies cal; nil when a name is missing", function()
  local fake = { getAngles = function() return { 2, 9 } end, getVelocity = function() return 3 end }
  local wrap = function(name) return name == "g" and fake or (name == "v" and fake) or nil end
  local a = SS.readAttitude({ gimbalPitchIdx = 1, gimbalRollIdx = 2, signVelMedial = 1 },
    { gimbal = "g", velMedial = "v" }, wrap)
  t.eq(a.pitch, 2); t.eq(a.roll, 9); t.eq(a.sas, 3)
  t.eq(SS.readAttitude({}, { gimbal = nil, velMedial = "v" }, wrap), nil, "missing gimbal name -> nil")
end)
