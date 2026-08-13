-- tests/test_pilot_modes.lua
local t = require("tests.framework")
local Pilot = require("fcs.input.pilot")
local FEEL = { headingRate=2.2, leadCapHeading=0.7, climbRate=4.5, leadCapVert=8,
  surgeSpeed=10, surgeLead=20, swaySpeed=5, swayLead=10, tiltRate=0.8, tiltCap=0.4,
  cruiseThrottleRate=1.0, cruiseThrottleMax=1.0 }
local function meas() return { altitude=0, heading=0, swayPos=0, surgePos=0 } end

t.test("MAN tilt ramps while held and auto-levels on release", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = true, surge = "position" }, FEEL); p:reset(meas())
  local a = p:update(0.1, { pitchUp = true }, meas())
  t.truthy(a.pitch > 0, "pitch ramps up while held")
  local held = a.pitch
  local b = p:update(0.1, {}, meas())          -- released
  t.truthy(b.pitch < held, "pitch decays toward level on release")
end)

t.test("MAN tilt is clamped to tiltCap", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = true, surge = "position" }, FEEL); p:reset(meas())
  for _ = 1, 50 do p:update(0.1, { rollRight = true }, meas()) end
  t.truthy(p:update(0, {}, meas()).roll <= 0.4 + 1e-9, "roll capped at tiltCap")
end)

t.test("CRUISE throttle ramps up, holds on release, ramps down on back", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = false, surge = "throttle" }, FEEL); p:reset(meas())
  local up = p:update(0.2, { surgeFwd = true }, meas())
  t.truthy(up.surgeThrottle > 0, "throttle rises")
  local hold = p:update(0.2, {}, meas())
  t.near(hold.surgeThrottle, up.surgeThrottle, 1e-9, "throttle holds on release")
  local down = p:update(0.2, { surgeBack = true }, meas())
  t.truthy(down.surgeThrottle < hold.surgeThrottle, "S ramps throttle down")
end)

t.test("PRECISION policy emits no tilt", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = false, surge = "position" }, FEEL); p:reset(meas())
  local sp = p:update(0.1, { pitchUp = true }, meas())
  t.truthy((sp.pitch or 0) == 0, "no pitch in non-tilt policy")
end)
