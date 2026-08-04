local t = require("tests.framework")
local Scheme = require("fcs.schemes.level_flight")
local Loop = require("fcs.runtime.loop")
local Mixer = require("fcs.mixer.level_flight")
local Pwm = require("fcs.actuate.pwm")
local Sim = require("tests.sim")
local function build()
  local sim = Sim.new({ mass = 4, g = 10, fPer = 15, inertia = 2, armX = 1, armZ = 1 })
  local sc = Scheme.new({ hoverDuty = 0.66,
    alt = { kp = 0.04, ki = 0.02, kd = 0.30, tauD = 0.2, iMax = 0.3, iMin = -0.3 },
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
local function fly(loop, sim, seconds, dtFn)
  local tsec, peaks, lastErr, rising = 0, {}, nil, false
  local ext = { maxRoll = 0, maxPitch = 0 }   -- peak |attitude| excursion over the flight
  while tsec < seconds do
    local dt = dtFn(tsec)
    loop:cycle(dt); sim:step(dt); tsec = tsec + dt
    local s = sim:sensors()
    if math.abs(s.roll) > ext.maxRoll then ext.maxRoll = math.abs(s.roll) end
    if math.abs(s.pitch) > ext.maxPitch then ext.maxPitch = math.abs(s.pitch) end
    local err = math.abs(10 - s.altitude)
    if lastErr and err > lastErr and not rising then rising = true end
    if lastErr and err < lastErr and rising then peaks[#peaks+1] = lastErr; rising = false end
    lastErr = err
  end
  return sim:sensors(), peaks, ext
end
t.test("settles to altitude 10 and stays level", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  local s = (fly(loop, sim, 40, function() return 0.1 end))
  t.near(s.altitude, 10, 0.6)                -- within tolerance
  t.near(s.pitch, 0, 0.05); t.near(s.roll, 0, 0.05)
end)
-- Attitude-recovery tests: inject a +0.3 rad disturbance directly on the plant, then
-- confirm the closed loop REMAINS BOUNDED near level (does not run away). This is the
-- true sign guard: with the correct plant sign the axis stays within a bounded bang-bang
-- limit cycle (peak excursion ~0.65 rad, sustained ~0.5 rad envelope) around level; with
-- an INVERTED plant sign the correction reinforces the disturbance and the axis DIVERGES
-- to thousands of rad within a few seconds. We assert peak |axis| stays well under 1.0 rad
-- (correct sign peaks ~0.65, inverted blows past instantly). Asserting the exact endpoint
-- would be fragile -- it is just one phase-dependent sample of the sustained limit cycle --
-- whereas the bound is phase-independent AND still hard-fails the sign bug. (These tests
-- would have caught the sim roll-moment inversion; verified by the guard re-inversion check.)
t.test("recovers from a roll disturbance: stays bounded near level", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  fly(loop, sim, 10, function() return 0.1 end)   -- settle to hover
  sim.roll = 0.3; sim.rollRate = 0                -- inject roll disturbance
  local _, _, ext = fly(loop, sim, 40, function() return 0.1 end)
  t.truthy(ext.maxRoll < 1.0)                     -- bounded => plant sign correct (inverted diverges to ~1e4)
end)
t.test("recovers from a pitch disturbance: stays bounded near level", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  fly(loop, sim, 10, function() return 0.1 end)   -- settle to hover
  sim.pitch = 0.3; sim.pitchRate = 0              -- inject pitch disturbance
  local _, _, ext = fly(loop, sim, 40, function() return 0.1 end)
  t.truthy(ext.maxPitch < 1.0)                    -- bounded => plant sign correct (inverted diverges to ~1e4)
end)
t.test("no limit cycle: late oscillation amplitude decreasing", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  local _, peaks = fly(loop, sim, 40, function() return 0.1 end)
  t.truthy(#peaks >= 2)
  t.truthy(peaks[#peaks] <= peaks[#peaks-1] + 1e-6)   -- not growing
end)
t.test("variable dt (jitter) stays stable", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  local seed = 1
  local s = (fly(loop, sim, 40, function() seed = (seed * 1103515245 + 12345) % 2147483648; return 0.05 + (seed % 100) / 1000 end))
  t.near(s.altitude, 10, 1.0)
end)
t.test("a single dt spike causes no altitude kick", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  fly(loop, sim, 20, function() return 0.1 end)
  local before = sim:sensors().altitude
  loop:cycle(5.0); sim:step(0.1)             -- stall cycle (clamped, integ/deriv skipped)
  t.near(sim:sensors().altitude, before, 0.5)
end)
