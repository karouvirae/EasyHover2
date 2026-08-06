local t = require("tests.framework")
local Scheme = require("fcs.schemes.level_flight")

local function m(alt)
  return { altitude = alt, pitch = 0, roll = 0, heading = 0, yawRate = 0,
           swayPos = 0, surgePos = 0, swayVel = 0, surgeVel = 0 }
end

t.test("heave band clamps the collective to [heaveMin, heaveMax]", function()
  local sc = Scheme.new({ hoverDuty = 0.72, heaveMin = 0.4, heaveMax = 0.85,
    alt = { kp = 1, ki = 0, kd = 0 } })   -- strong kp so the error drives heave past the rails
  t.near(sc:update({ altitude = 10 }, m(0), 0.1, false).heave, 0.85, 1e-9)  -- 0.72+10 -> clamp hi
  t.near(sc:update({ altitude = 0 }, m(10), 0.1, false).heave, 0.4, 1e-9)   -- 0.72-10 -> clamp lo
end)
t.test("no band configured leaves heave unclamped (backward compat)", function()
  local sc = Scheme.new({ hoverDuty = 0.5, alt = { kp = 1, ki = 0, kd = 0 } })
  t.near(sc:update({ altitude = 10 }, m(0), 0.1, false).heave, 10.5, 1e-9)
end)
