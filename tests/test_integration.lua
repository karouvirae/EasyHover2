local t = require("tests.framework")
local Scheme = require("fcs.schemes.level_flight")
local Loop = require("fcs.runtime.loop")
local Mixer = require("fcs.mixer.level_flight")
local Pwm = require("fcs.actuate.pwm")
local Sim = require("tests.sim")
local function build()
  local sim = Sim.new({ mass = 4, g = 10, fPer = 15, inertia = 2, armX = 1, armZ = 1 })
  local sc = Scheme.new({ hoverDuty = 0.66,
    alt = { kp = 0.05, ki = 0.02, kd = 0.0, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.3, ki = 0, kd = 0.08, tauD = 0.2 },
    roll = { kp = 0.3, ki = 0, kd = 0.08, tauD = 0.2 } })
  local loop = Loop.new({ scheme = sc, mixer = Mixer.new(),
    pwm = Pwm.new({ period = 0.3, backend = sim }), backend = sim, dtMax = 0.5 })
  return loop, sim
end
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
t.test("disarmed on the ground commands no thrust", function()
  local loop, sim = build()
  loop:arm(false); loop:setpoints({ altitude = 5, pitch = 0, roll = 0 })
  for _ = 1, 20 do loop:cycle(0.05); sim:step(0.05) end
  t.truthy(sim:sensors().altitude <= 0)      -- never left the ground
end)
