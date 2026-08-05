local t = require("tests.framework")
local hwconfig = require("fcs.io.hwconfig")
t.test("defaults has all thruster + sensor roles unbound", function()
  local d = hwconfig.defaults()
  t.truthy(d.thrusters.FL == false); t.truthy(d.sensors.gimbal == false)
  t.near(d.bindings.onGroundThreshold, 1.5, 1e-9)
end)
t.test("merge fills missing keys from defaults, keeps saved values", function()
  local saved = { thrusters = { FL = "thruster_3" }, bindings = { signPitch = -1 } }
  local m = hwconfig.merge(saved, hwconfig.defaults())
  t.truthy(m.thrusters.FL == "thruster_3")     -- kept
  t.truthy(m.thrusters.FR == false)            -- filled
  t.near(m.bindings.signPitch, -1, 1e-9)       -- kept
  t.near(m.bindings.heightOffset, 0, 1e-9)     -- filled
end)
