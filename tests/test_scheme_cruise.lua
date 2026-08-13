-- tests/test_scheme_cruise.lua
local t = require("tests.framework")
local Cruise = require("fcs.schemes.cruise")
local Level  = require("fcs.schemes.level_flight")
local cfg = { hoverDuty = 0.26, alt = {kp=0.02,ki=0.01,kd=0.15,tauD=0.35},
  pitch = {kp=0.1,kd=0.22}, roll = {kp=0.1,kd=0.22}, yaw = {kp=0.95,kd=1.0},
  sway = {kp=0.2,kd=0.25}, surge = {kp=0.15,kd=0.25}, heaveMin = 0.05, heaveMax = 0.85 }

t.test("CRUISE holds surge at the throttle setpoint, other axes match level", function()
  local cru, lvl = Cruise.new(cfg), Level.new(cfg)
  local sp = { altitude = 5, swayPos = 2, surgeThrottle = 0.7 }
  local m = { altitude = 2, pitch = 0, roll = 0, heading = 0, yawRate = 0,
    swayPos = 0, swayVel = 0, surgePos = 0, surgeVel = 0 }
  local dc = cru:update(sp, m, 0.05, false)
  local dl = lvl:update(sp, m, 0.05, false)
  t.near(dc.surge, 0.7, 1e-9, "surge held at throttle")
  t.near(dc.heave, dl.heave, 1e-9, "heave matches level")
  t.near(dc.sway, dl.sway, 1e-9, "sway (lateral hold) matches level")
end)

t.test("CRUISE surge defaults to 0 when no throttle setpoint", function()
  local cru = Cruise.new(cfg)
  local m = { altitude = 1, pitch = 0, roll = 0, heading = 0, yawRate = 0,
    swayPos = 0, swayVel = 0, surgePos = 0, surgeVel = 0 }
  local d = cru:update({ altitude = 1 }, m, 0.05, false)
  t.eq(d.surge, 0, "no throttle => zero surge")
end)
