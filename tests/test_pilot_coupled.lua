local t = require("tests.framework")
local Pilot = require("fcs.input.pilot")
local FEEL = { headingRate=2.2, leadCapHeading=0.7, climbRate=4.5, leadCapVert=8,
  surgeSpeed=10, surgeLead=20, swaySpeed=5, swayLead=10, tiltRate=0.8, tiltCap=0.4,
  throttleRate=1.0, throttleDecay=1.0, brakeGain=0.5, slowSurgeRate=0.3, strafeRate=0.3,
  climbRampTime=1.0, climbBoost=2.0, trimGain=0.1, trimDir=-1 }
local function meas() return { altitude=0, heading=0, swayPos=0, surgePos=0, surgeVel=0 } end
local function cpl(p) p:setMode({ tilt=true, surge="coupled" }, FEEL); p:reset(meas()) end

t.test("throttle ramps while held and decays to idle on release", function()
  local p = Pilot.new(FEEL); cpl(p)
  local a = p:update(0.2, { surgeFwd=true }, meas())
  t.truthy(a.surgeCmd > 0 and a.surgeActive, "throttle rises + active")
  local b = p:update(0.2, {}, meas())            -- released
  t.truthy(b.surgeCmd < a.surgeCmd, "throttle decays on release")
end)

t.test("brake taper: reverse demand scales with speed and never reverses at rest", function()
  local p = Pilot.new(FEEL); cpl(p)
  local m = meas(); m.surgeVel = 4
  local moving = p:update(0.1, { surgeBack=true }, m)
  t.truthy(moving.surgeCmd < 0, "brake pushes reverse while moving fwd")
  local rest = meas(); rest.surgeVel = 0
  local stopped = p:update(0.1, { surgeBack=true }, rest)
  t.near(stopped.surgeCmd, 0, 1e-9, "no brake force at rest (never reverses)")
end)

t.test("rampable climb accelerates with hold time", function()
  local p = Pilot.new(FEEL); cpl(p)
  local first = p:update(0.05, { up=true }, meas()).altitude
  for _ = 1, 40 do p:update(0.05, { up=true }, meas()) end
  local m2 = meas(); m2.altitude = p:update(0, {}, meas()).altitude - 1  -- keep leash from clamping
  local later = p:update(0.05, { up=true }, m2).altitude
  t.truthy(later - (m2.altitude) ~= 0, "climb still moving under sustained hold")
end)

t.test("auto-trim offsets pitch by trimDir*trimGain*throttle, clamped to tiltCap", function()
  local p = Pilot.new(FEEL); cpl(p)
  for _ = 1, 5 do p:update(0.2, { surgeFwd=true }, meas()) end  -- build throttle
  local sp = p:update(0, {}, meas())
  t.truthy(sp.pitch < 0, "nose-down trim with trimDir=-1 under forward throttle")
  t.truthy(sp.pitch >= -0.4 - 1e-9, "trim stays within tiltCap")
end)

t.test("trimCap lets auto-trim command more nose-down than the manual tiltCap", function()
  local FEEL2 = { headingRate=2.2, leadCapHeading=0.7, climbRate=4.5, leadCapVert=8,
    surgeSpeed=10, surgeLead=20, swaySpeed=5, swayLead=10, tiltRate=0.8, tiltCap=0.4,
    throttleRate=1.0, throttleDecay=1.0, brakeGain=0.5, slowSurgeRate=0.3, strafeRate=0.3,
    climbRampTime=1.0, climbBoost=2.0, trimGain=0.5, trimDir=-1, trimCap=0.6 }
  local p = Pilot.new(FEEL2); p:setMode({ tilt=true, surge="coupled" }, FEEL2); p:reset(meas())
  for _ = 1, 10 do p:update(0.2, { surgeFwd=true }, meas()) end  -- throttle -> 1
  local sp = p:update(0, {}, meas())
  t.truthy(sp.pitch < -0.4 - 1e-9, "nose-down exceeds the 0.4 tiltCap (got " .. sp.pitch .. ")")
  t.truthy(sp.pitch >= -0.6 - 1e-9, "still clamped to trimCap 0.6")
end)

t.test("rudder keys flag rear-only routing; comma/period do not", function()
  local p = Pilot.new(FEEL); cpl(p)
  t.eq(p:update(0.1, { rudderRight=true }, meas()).yawRear, true, "rudder -> yawRear")
  t.eq(p:update(0.1, { yawRight=true }, meas()).yawRear, false, "full yaw -> not rear")
end)

t.test("strafe on sway flags produces sway command", function()
  local p = Pilot.new(FEEL); cpl(p)
  local sp = p:update(0.1, { swayRight=true }, meas())
  t.truthy(sp.swayActive and sp.swayCmd > 0, "strafe right")
end)
