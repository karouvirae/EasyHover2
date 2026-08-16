package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local S = require("tools.splitconfig")
local cfgspec = require("fcs.io.cfgspec")

local function fused()
  return {
    thrusters = { FL = "thruster_1" }, sensors = { gimbal = "gimbal_1", velMedial = "vel_1" },
    fuelRelay = "redstone_relay_0",
    bindings = { signPitch = 1, signHeading = -1, gimbalScale = 1 },
  }
end

t.test("plan derives + validates devbind and senscal from a fused table", function()
  local r = S.plan({ fused = fused(), hasDevbind = false, hasSenscal = false })
  t.eq(r.action, "write")
  t.eq(r.devbind.thrusters.FL, "thruster_1")
  t.eq(r.devbind.sensors.gimbal, "gimbal_1")
  t.eq(r.senscal.signPitch, 1)
  t.truthy(cfgspec.validate("devbind", r.devbind), "devbind valid")
  t.truthy(cfgspec.validate("senscal", r.senscal), "senscal valid")
end)

t.test("plan is a no-op when both split files already exist", function()
  local r = S.plan({ fused = fused(), hasDevbind = true, hasSenscal = true })
  t.eq(r.action, "already-split")
end)

t.test("plan only fills the missing split when one already exists", function()
  local r = S.plan({ fused = fused(), hasDevbind = true, hasSenscal = false })
  t.eq(r.action, "write"); t.eq(r.devbind, nil); t.truthy(r.senscal, "senscal derived")
end)

t.test("plan aborts on a nil/invalid fused table", function()
  t.eq(S.plan({ fused = nil, hasDevbind = false, hasSenscal = false }).action, "abort")
  t.eq(S.plan({ fused = "x", hasDevbind = false, hasSenscal = false }).action, "abort")
end)
