-- tests/test_tuning_modes.lua
local t = require("tests.framework")
local tuning = require("fcs.tuning")

t.test("forMode PRECISION returns the top-level tuning", function()
  local p = tuning.forMode("PRECISION")
  t.eq(p.gains, tuning.gains, "PRECISION gains are the top-level gains")
  t.eq(p.caps, tuning.caps, "PRECISION caps are the top-level caps")
end)

t.test("forMode MAN relaxes tilt and adds tilt feel", function()
  local m = tuning.forMode("MAN")
  t.truthy(m.caps.pitch > 0.2, "MAN pitch cap relaxed above default 0.2")
  t.truthy(m.feel.tiltRate and m.feel.tiltCap, "MAN has tilt feel params")
end)

t.test("forMode CRUISE adds surge-throttle feel", function()
  local c = tuning.forMode("CRUISE")
  t.truthy(c.feel.cruiseThrottleMax and c.feel.cruiseThrottleRate, "CRUISE has throttle feel")
end)

t.test("mode records are independent (mutating MAN never touches PRECISION/CRUISE)", function()
  local man = tuning.forMode("MAN")
  man.gains.yaw.kp = 999
  t.truthy(tuning.forMode("PRECISION").gains.yaw.kp ~= 999, "PRECISION untouched")
  t.truthy(tuning.forMode("CRUISE").gains.yaw.kp ~= 999, "CRUISE untouched")
end)
