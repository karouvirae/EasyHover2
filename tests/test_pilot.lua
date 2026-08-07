local t = require("tests.framework")
local Pilot = require("fcs.input.pilot")

local CFG = { headingRate = 1.0, climbRate = 0.5, leadCapVert = 2.0,
              cruiseSpeed = 1.0, maxLead = 3.0 }
local function meas(o) o = o or {}
  return { altitude = o.altitude or 10, heading = o.heading or 0,
           swayPos = o.swayPos or 0, surgePos = o.surgePos or 0 }
end

t.test("reset seeds setpoints to current craft state", function()
  local p = Pilot.new(CFG)
  local sp = p:reset(meas{altitude=12, heading=0.3, swayPos=1, surgePos=-2})
  t.eq(sp.altitude, 12); t.eq(sp.heading, 0.3)
  t.eq(sp.swayPos, 1); t.eq(sp.surgePos, -2)
end)

t.test("yaw held ramps heading by headingRate*dt, wrapped", function()
  local p = Pilot.new(CFG); p:reset(meas())
  local sp = p:update(0.5, {yawRight=true}, meas())
  t.near(sp.heading, 0.5, 1e-9, "heading +0.5")
  sp = p:update(0.5, {yawLeft=true}, meas())
  t.near(sp.heading, 0.0, 1e-9, "back to 0")
end)

t.test("lift held ramps altitude, leashed to meas.alt +/- leadCapVert", function()
  local p = Pilot.new(CFG); p:reset(meas{altitude=10})
  -- climbRate 0.5 * dt 10 = +5 requested, but leashed to alt(10)+leadCapVert(2)=12
  local sp = p:update(10, {up=true}, meas{altitude=10})
  t.near(sp.altitude, 12, 1e-9, "clamped to +leadCapVert")
end)

t.test("sway held ramps swayPos at cruiseSpeed, clamped to maxLead", function()
  local p = Pilot.new(CFG); p:reset(meas())
  local sp = p:update(1.0, {swayRight=true}, meas())   -- +1 (cruise 1 * dt 1)
  t.near(sp.swayPos, 1.0, 1e-9, "swayPos +1")
  sp = p:update(10, {swayRight=true}, meas())           -- would be +10, clamped to maxLead 3
  t.near(sp.swayPos, 3.0, 1e-9, "clamped to maxLead")
end)

t.test("surge forward increases surgePos (fwd = main thrust)", function()
  local p = Pilot.new(CFG); p:reset(meas())
  local sp = p:update(1.0, {surgeFwd=true}, meas())
  t.near(sp.surgePos, 1.0, 1e-9, "surgePos +1")
end)

t.test("release holds setpoints where they are", function()
  local p = Pilot.new(CFG); p:reset(meas())
  p:update(1.0, {swayRight=true}, meas())
  -- craft has not moved (meas.swayPos still 0); releasing keeps sp at 1
  local sp = p:update(1.0, {}, meas{swayPos=0.5})
  t.near(sp.swayPos, 1.0, 1e-9, "held at 1")
end)

t.test("position hold freezes setpoints and ignores held", function()
  local p = Pilot.new(CFG); p:reset(meas{heading=0.2, swayPos=1})
  p:setPositionHold(true)
  local sp = p:update(1.0, {yawRight=true, swayRight=true}, meas())
  t.near(sp.heading, 0.2, 1e-9, "heading frozen")
  t.near(sp.swayPos, 1.0, 1e-9, "sway frozen")
end)
