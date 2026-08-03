local t = require("tests.framework")
local Scheme = require("fcs.schemes.level_flight")
t.test("scheme outputs hover heave at altitude setpoint, level", function()
  local sc = Scheme.new({
    hoverDuty = 0.66,
    alt = { kp = 0.05, ki = 0.0, kd = 0.0 },
    pitch = { kp = 0.2, ki = 0, kd = 0.05, tauD = 0.2 },
    roll = { kp = 0.2, ki = 0, kd = 0.05, tauD = 0.2 },
  })
  local d = sc:update({ altitude = 10, pitch = 0, roll = 0 },
                      { altitude = 10, vSpeed = 0, pitch = 0, pitchRate = 0, roll = 0, rollRate = 0 }, 0.1)
  t.near(d.heave, 0.66, 1e-9); t.near(d.pitch, 0, 1e-9); t.near(d.roll, 0, 1e-9)
end)
