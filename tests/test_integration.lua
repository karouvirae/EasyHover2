local t = require("tests.framework")
local Scheme = require("fcs.schemes.level_flight")
local Loop = require("fcs.runtime.loop")
local Mixer = require("fcs.mixer.level_flight")
local Pwm = require("fcs.actuate.pwm")
local Sim = require("tests.sim")
local Heading = require("fcs.control.heading")
local function build()
  local sim = Sim.new({ mass = 4, g = 10, fPer = 15, inertia = 2, armX = 1, armZ = 1,
    fPerLat = 6, yawInertia = 8, fMain = 20, fFrontal = 10 })
  local sc = Scheme.new({ hoverDuty = 0.66,
    alt = { kp = 0.04, ki = 0.02, kd = 0.30, tauD = 0.2, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    roll = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    yaw = { kp = 0.5, ki = 0, kd = 0.2 },
    sway = { kp = 0.5, ki = 0, kd = 0.5 },
    surge = { kp = 0.3, ki = 0, kd = 0.5 } })
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
t.test("scheme emits a yaw demand toward the heading setpoint", function()
  local sc = Scheme.new({ hoverDuty = 0.66,
    alt = { kp = 0.04, ki = 0.02, kd = 0.30, tauD = 0.2, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    roll  = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    yaw   = { kp = 0.5, ki = 0, kd = 0.2 } })
  local d = sc:update({ altitude = 10, pitch = 0, roll = 0, heading = 0.4 },
                      { altitude = 10, vSpeed = 0, pitch = 0, pitchRate = 0, roll = 0, rollRate = 0,
                        heading = 0.0, yawRate = 0.0 }, 0.1)
  t.truthy(d.yaw > 0)                     -- +0.4 heading error -> yaw right
end)
t.test("disarmed on the ground commands no thrust", function()
  local loop, sim = build()
  loop:arm(false); loop:setpoints({ altitude = 5, pitch = 0, roll = 0 })
  for _ = 1, 20 do loop:cycle(0.05); sim:step(0.05) end
  t.truthy(sim:sensors().altitude <= 0)      -- never left the ground
end)
local function fly(loop, sim, seconds, dtFn)
  local tsec, peaks, lastErr, rising = 0, {}, nil, false
  -- ext: peak |attitude| over the whole flight, AND over the FINAL THIRD only
  -- (lateRoll/latePitch). The late-window peak proves convergence: it collapses to
  -- ~0 when the loop re-levels, but stays large under a sustained limit cycle or a
  -- divergent (wrong-sign) response.
  local ext = { maxRoll = 0, maxPitch = 0, lateRoll = 0, latePitch = 0 }
  local lateStart = seconds * (2/3)
  while tsec < seconds do
    local dt = dtFn(tsec)
    loop:cycle(dt); sim:step(dt); tsec = tsec + dt
    local s = sim:sensors()
    local ar, ap = math.abs(s.roll), math.abs(s.pitch)
    if ar > ext.maxRoll then ext.maxRoll = ar end
    if ap > ext.maxPitch then ext.maxPitch = ap end
    if tsec >= lateStart then
      if ar > ext.lateRoll then ext.lateRoll = ar end
      if ap > ext.latePitch then ext.latePitch = ap end
    end
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
-- confirm the closed loop RE-LEVELS -- the attitude amplitude in the FINAL THIRD of the
-- flight collapses to near zero. With the damped attitude gains (kd = 0.4) the loop drives
-- the axis back to level and freezes it there (all four corners then toggle in lockstep at
-- equal duty -> zero net moment), so the late-window residual is ~0. This is a strictly
-- stronger assertion than the earlier boundedness bound: it fails BOTH a sustained bang-bang
-- limit cycle (old kd = 0.08 held a ~0.5 rad envelope) AND a wrong-sign/divergent response
-- (an INVERTED plant reinforces the disturbance and the axis runs away to thousands of rad).
-- So it doubles as the plant-sign guard. Threshold 0.05 rad (~3 deg); measured residual ~0.
local RECOVER = 0.05
t.test("recovers from a roll disturbance: re-levels to near zero", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  fly(loop, sim, 10, function() return 0.1 end)   -- settle to hover
  sim.roll = 0.3; sim.rollRate = 0                -- inject roll disturbance
  local _, _, ext = fly(loop, sim, 40, function() return 0.1 end)
  t.truthy(ext.lateRoll < RECOVER)                -- converges to level (inverted sign diverges to ~1e4)
end)
t.test("recovers from a pitch disturbance: re-levels to near zero", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  fly(loop, sim, 10, function() return 0.1 end)   -- settle to hover
  sim.pitch = 0.3; sim.pitchRate = 0              -- inject pitch disturbance
  local _, _, ext = fly(loop, sim, 40, function() return 0.1 end)
  t.truthy(ext.latePitch < RECOVER)               -- converges to level (inverted sign diverges to ~1e4)
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
t.test("holds commanded heading and converges from a yaw disturbance", function()
  local loop, sim = build(); loop:arm(true)
  loop:setpoints({ altitude = 10, pitch = 0, roll = 0, heading = 0.0 })
  fly(loop, sim, 10, function() return 0.1 end)   -- settle
  sim.heading = 0.6; sim.yawRate = 0               -- inject a heading disturbance (~34 deg)
  fly(loop, sim, 25, function() return 0.1 end)
  t.near(sim:sensors().heading, 0.0, 0.05)         -- re-levels heading (would fail on a limit cycle / wrong sign)
end)
t.test("captures and holds a new commanded heading", function()
  local loop, sim = build(); loop:arm(true)
  loop:setpoints({ altitude = 10, pitch = 0, roll = 0, heading = 0.8 })
  fly(loop, sim, 30, function() return 0.1 end)
  t.near(sim:sensors().heading, 0.8, 0.05)         -- flew to the commanded heading and held
end)
t.test("scheme emits sway/surge force toward a position setpoint", function()
  local sc = Scheme.new({ hoverDuty = 0.66,
    alt = { kp = 0.04, ki = 0.02, kd = 0.30, tauD = 0.2, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    roll  = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    yaw   = { kp = 0.5, ki = 0, kd = 0.2 },
    sway  = { kp = 0.3, ki = 0, kd = 0.4 },
    surge = { kp = 0.3, ki = 0, kd = 0.4 } })
  local m = { altitude=10, vSpeed=0, pitch=0, pitchRate=0, roll=0, rollRate=0,
    heading=0, yawRate=0, swayPos=0, swayVel=0, surgePos=0, surgeVel=0 }
  local d = sc:update({ altitude=10, pitch=0, roll=0, heading=0, swayPos=1, surgePos=-1 }, m, 0.1)
  t.truthy(d.sway > 0)     -- +swayPos error -> push right
  t.truthy(d.surge < 0)    -- -surgePos error -> push back
end)
t.test("damps a sideways drift back to zero position", function()
  local loop, sim = build(); loop:arm(true)
  loop:setpoints({ altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 })
  fly(loop, sim, 8, function() return 0.1 end)
  sim.swayVel = 1.5; sim.swayPos = 0        -- shove sideways
  fly(loop, sim, 25, function() return 0.1 end)
  t.near(sim:sensors().swayPos, 0, 0.1)     -- returns to station (would fail on runaway/wrong sign)
end)
t.test("translates forward to a commanded position and holds", function()
  local loop, sim = build(); loop:arm(true)
  loop:setpoints({ altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=3 })
  fly(loop, sim, 30, function() return 0.1 end)
  t.near(sim:sensors().surgePos, 3, 0.15)   -- flew forward 3m and held
end)
t.test("freeze flag stops integral windup across the scheme", function()
  local sc = Scheme.new({ hoverDuty = 0.66,
    alt = { kp = 0, ki = 1, kd = 0 }, pitch = { kp=0,ki=0,kd=0 }, roll = { kp=0,ki=0,kd=0 },
    yaw = { kp=0,ki=0,kd=0 }, sway = { kp=0,ki=0,kd=0 }, surge = { kp=0,ki=0,kd=0 } })
  local m = { altitude=0, vSpeed=0, pitch=0, pitchRate=0, roll=0, rollRate=0,
    heading=0, yawRate=0, swayPos=0, swayVel=0, surgePos=0, surgeVel=0 }
  local sp = { altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 }
  for _ = 1, 20 do sc:update(sp, m, 0.1, true) end          -- frozen: no windup
  t.near(sc:update(sp, m, 0, true).heave, 0.66, 1e-9)        -- heave == hoverDuty (I stayed 0)
end)
t.test("leash caps the commanded lead distance", function()
  -- with a leashed setpoint the position error can't exceed maxLead
  local leash = require("fcs.leash")
  local sp = 0
  for _ = 1, 100 do sp = leash.step(sp, 1000, 0, 0.1, 5, 2.0) end
  t.near(sp, 2.0, 1e-9)                      -- pinned at pos(0)+maxLead(2)
end)
