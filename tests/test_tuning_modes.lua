-- tests/test_tuning_modes.lua
local t = require("tests.framework")
local tuning = require("fcs.tuning")
local tuningdefaults = require("fcs.io.tuningdefaults")

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

t.test("forMode CPL adds trim feel", function()
  local c = tuning.forMode("CPL")
  t.truthy(c.feel.trimGain, "CPL has trimGain")
  t.truthy(c.feel.trimDir, "CPL has trimDir")
end)

t.test("tuningdefaults CPL record carries trim feel", function()
  local d = tuningdefaults.get()
  t.truthy(d.modes.CPL.feel.trimGain, "CPL trimGain exists")
  t.truthy(d.modes.CPL.feel.trimDir, "CPL trimDir exists")
end)

t.test("CPL/DCPL carry strengthened nose-down trim authority", function()
  local cpl = tuning.forMode("CPL")
  t.near(cpl.feel.trimGain, 0.35, 1e-9, "trimGain strengthened for real nose-down")
  t.near(cpl.feel.trimCap, 0.5, 1e-9, "trimCap headroom beyond the manual tiltCap")
  t.near(cpl.caps.pitch, 0.5, 1e-9, "pitch torque cap raised so the mixer isn't the limiter")
  local dcpl = tuning.forMode("DCPL")
  t.near(dcpl.feel.trimGain, 0.35, 1e-9, "DCPL trimGain strengthened")
  t.near(dcpl.feel.trimCap, 0.5, 1e-9, "DCPL trimCap present")
  t.near(dcpl.caps.pitch, 0.5, 1e-9, "DCPL pitch cap raised")
end)

t.test("yaw defaults detuned for a crisp release stop (lower turn rate + more damping)", function()
  -- Higher-momentum heavy craft overshoots on release. Halve the turn rate (leadCapHeading) and
  -- raise yaw kd so the craft stops near release instead of ringing back 20-30deg.
  local p = tuning.forMode("PRECISION")
  t.near(p.gains.yaw.kd, 1.8, 1e-9, "yaw kd raised for damping")
  t.near(p.feel.leadCapHeading, 0.35, 1e-9, "yaw turn rate (lead cap) halved")
  local man = tuning.forMode("MAN")
  t.near(man.gains.yaw.kd, 1.8, 1e-9, "MAN inherits the damped yaw")
  t.near(man.feel.leadCapHeading, 0.35, 1e-9, "MAN inherits the lower turn rate")
end)

t.test("yawStopLead is a live feel knob across the tilt modes (snappy-yaw release stop)", function()
  t.truthy(tuning.forMode("PRECISION").feel.yawStopLead ~= nil, "PRECISION has yawStopLead")
  t.truthy(tuning.forMode("MAN").feel.yawStopLead ~= nil, "MAN has yawStopLead")
  t.truthy(tuning.forMode("CPL").feel.yawStopLead ~= nil, "CPL has yawStopLead")
end)

t.test("mode records are independent (mutating MAN never touches PRECISION/CRUISE)", function()
  local man = tuning.forMode("MAN")
  man.gains.yaw.kp = 999
  t.truthy(tuning.forMode("PRECISION").gains.yaw.kp ~= 999, "PRECISION untouched")
  t.truthy(tuning.forMode("CRUISE").gains.yaw.kp ~= 999, "CRUISE untouched")
end)
