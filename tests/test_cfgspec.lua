local t = require("tests.framework")
local C = require("fcs.io.cfgspec")

t.test("defaults + merge are additive per kind", function()
  local d = C.defaults("devbind")
  t.truthy(d.thrusters and d.sensors, "devbind shape")
  local m = C.merge("devbind", { thrusters = { FL = "thruster_3" } })
  t.eq(m.thrusters.FL, "thruster_3", "saved wins")
  t.eq(m.thrusters.FR, false, "default fills the rest")
end)

t.test("validate accepts good, rejects wrong shape", function()
  t.eq((C.validate("tuning", C.defaults("tuning"))), true)
  local ok, err = C.validate("devbind", { nope = 1 })
  t.eq(ok, false)
  t.truthy(err)
end)

t.test("load merges saved over defaults via injected reader", function()
  local body = textutils.serialise({ bindings = nil, thrusters = { MAIN = "thruster_9" } })
  local m = C.load("devbind", function() return body end)
  t.eq(m.thrusters.MAIN, "thruster_9")
end)

t.test("legacy hw_config splits and reassembles losslessly (no calibration lost)", function()
  local hw = require("fcs.io.hwconfig").merge({
    thrusters = { FL = "thruster_1" }, sensors = { gimbal = "gimbal_0" },
    fuelRelay = "relay_0", bindings = { signHeading = -1, heightOffset = -94.5, signPitch = -1 },
  }, require("fcs.io.hwconfig").defaults())
  local split = C.splitLegacy(hw)
  t.eq(split.devbind.thrusters.FL, "thruster_1"); t.eq(split.senscal.signHeading, -1)
  local hw2 = C.assembleHw(split.devbind, split.senscal)
  t.eq(hw2.thrusters.FL, "thruster_1"); t.eq(hw2.sensors.gimbal, "gimbal_0")
  t.eq(hw2.fuelRelay, "relay_0"); t.eq(hw2.bindings.heightOffset, -94.5); t.eq(hw2.bindings.signHeading, -1)
end)
