local t = require("tests.framework")
local Coupled = require("fcs.schemes.coupled")
local Decoupled = require("fcs.schemes.decoupled")
local GAINS = { hoverDuty = 0.26,
  alt = { kp=0.02, ki=0.01, kd=0.15, tauD=0.35, iMax=0.3, iMin=-0.3 },
  pitch = { kp=0.1, kd=0.22, tauD=0.2 }, roll = { kp=0.1, kd=0.22, tauD=0.2 },
  yaw = { kp=0.95, kd=1.0 }, sway = { kp=0.2, kd=0.25 }, surge = { kp=0.15, kd=0.25 },
  heaveMin = 0.05, heaveMax = 0.85 }
local function meas() return { altitude=0, pitch=0, roll=0, heading=0, yawRate=0,
  swayPos=0, swayVel=0, surgePos=0, surgeVel=0 } end

t.test("CPL: pilot surge command overrides the position loop when active", function()
  local s = Coupled.new(GAINS); s:reset()
  local d = s:update({ altitude=0, surgeCmd = 0.7, surgeActive = true }, meas(), 0.05, false)
  t.near(d.surge, 0.7, 1e-9, "surge follows pilot command")
end)

t.test("CPL: idle surge falls back to the inner cushion (not zero)", function()
  local s = Coupled.new(GAINS); s:reset()
  -- craft drifting forward, no pilot input: inner translate damps it (nonzero corrective surge)
  local m = meas(); m.surgePos = 3; m.surgeVel = 2
  local d = s:update({ altitude=0, surgePos = 0, surgeActive = false }, m, 0.05, false)
  t.truthy(d.surge ~= 0, "CPL arrests drift when idle (cushion)")
end)

t.test("DCPL: idle surge/sway forced to zero (momentum coasts)", function()
  local s = Decoupled.new(GAINS); s:reset()
  local m = meas(); m.surgePos = 3; m.surgeVel = 2; m.swayPos = 3; m.swayVel = 2
  local d = s:update({ altitude=0, surgeActive = false, swayActive = false }, m, 0.05, false)
  t.eq(d.surge, 0, "DCPL does not arrest surge drift")
  t.eq(d.sway, 0, "DCPL does not arrest sway drift")
end)

t.test("CPL: yawRear reroutes the heading-loop yaw to the rear-only demand", function()
  local s = Coupled.new(GAINS); s:reset()
  local m = meas(); m.heading = -0.5   -- heading error so the heading PID emits a nonzero yaw
  local d = s:update({ altitude=0, heading=0, yawRear = true }, m, 0.05, false)
  t.truthy((d.yawRear or 0) ~= 0, "rudder yaw goes to yawRear")
  t.eq(d.yaw, 0, "full-yaw demand zeroed when rerouted")
end)
