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
t.test("alt integrator stops winding up while heave is saturated at the band (anti-windup)", function()
  -- Heave pinned to heaveMax by a large sustained error: without anti-windup the alt integrator
  -- keeps accumulating every tick (climb-stop overshoot). With it, the band saturation freezes
  -- integration after one tick, so `i` stays ~one-tick-small instead of growing unbounded.
  local sc = Scheme.new({ hoverDuty = 0.5, heaveMin = 0.05, heaveMax = 0.85,
    alt = { kp = 0.1, ki = 1.0, kd = 0 } })    -- no iMax: isolate the band anti-windup
  for _ = 1, 50 do sc:update({ altitude = 100 }, m(0), 0.1, false) end
  t.truthy(sc.altPid.i < 20, "integrator frozen once saturated, not wound up over 50 ticks")
end)

-- ---- envelope saturation feedback (per-axis anti-windup) ----
t.test("envelope sat flag freezes the railed axis's integrator next tick", function()
  local sc = Scheme.new({ hoverDuty = 0.5,
    pitch = { kp = 1, ki = 0.5, kd = 0 } })   -- no iMax: isolate the feedback
  local mm = m(0)
  local sp = { altitude = 0, pitch = -1 }     -- sustained +error winds the integrator up
  sc:update(sp, mm, 0.1, false)               -- normal tick
  local i1 = sc.pitchPid.i
  t.truthy(i1 ~= 0, "integrator alive")
  sc:update(sp, mm, 0.1, false, { pitch = true })  -- railed last tick
  t.eq(sc.pitchPid.i, i1, "integration skipped while envelope-flagged")
  sc:update(sp, mm, 0.1, false)               -- rail released
  t.truthy(math.abs(sc.pitchPid.i) > math.abs(i1), "integration resumes when the flag clears")
end)

t.test("envelope sat on heave freezes the alt integrator (same as band saturation)", function()
  local sc = Scheme.new({ hoverDuty = 0.5, alt = { kp = 0.1, ki = 1.0, kd = 0 } })
  sc:update({ altitude = 100 }, m(0), 0.1, false)
  local i1 = sc.altPid.i
  sc:update({ altitude = 100 }, m(0), 0.1, false, { heave = true })
  t.eq(sc.altPid.i, i1, "alt integration skipped while heave envelope-flagged")
end)

t.test("alt integrator does NOT wind up on a large climb-tracking error (conditional integration)", function()
  -- The reported bug: during a fast climb the setpoint leads the craft by up to leadCapVert(8)
  -- blocks, so err_alt is large and sustained WITHOUT heave saturating (heave sits mid-band ~0.25).
  -- The existing sat/band anti-windup never triggers, so `i` wound to iMax(0.3) and then floated the
  -- craft past the setpoint -- a long, oscillatory drop. An alt iBand freezes integration outside the
  -- band, so `i` stays near zero on the climb error (P drives the climb; I only trims near setpoint).
  local sc = Scheme.new({ hoverDuty = 0.26, heaveMin = 0.05, heaveMax = 0.85,
    alt = { kp = 0.02, ki = 0.01, kd = 0, iMax = 0.3, iBand = 3 } })
  for _ = 1, 100 do sc:update({ altitude = 8 }, m(0), 0.1, false) end  -- 10s of err=8 climb, heave unrailed
  t.truthy(sc._heaveSat == false, "sanity: heave never railed, so band/sat anti-windup is NOT what holds it")
  t.truthy(math.abs(sc.altPid.i) < 0.02, "alt integrator stays near zero on a large climb error, not wound to iMax")
end)
t.test("alt integrator still trims a small steady-state error within the band", function()
  local sc = Scheme.new({ hoverDuty = 0.26, heaveMin = 0.05, heaveMax = 0.85,
    alt = { kp = 0.02, ki = 0.5, kd = 0, iMax = 0.3, iBand = 3 } })
  for _ = 1, 20 do sc:update({ altitude = 2 }, m(0), 0.1, false) end   -- err=2 within band 3
  t.truthy(sc.altPid.i > 0.05, "integrator trims the steady-state residual when the craft is near the setpoint")
end)
