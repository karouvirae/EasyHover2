-- tests/modes_golden_data.lua
-- Shared golden-baseline data: the deterministic input battery and the frozen PRECISION
-- per-thruster outputs captured from the pristine (pre-flight-modes) fcs/schemes/level_flight.lua
-- and fcs/mixer/level_flight.lua via tools/capture_precision_golden.lua. This is a
-- characterization lock -- EXPECT must not change unless a later task intentionally changes
-- PRECISION's flight behavior.
--
-- Reused by tests/test_modes_golden.lua (this task) and Task 5's parity check.

local function schemeCfg(gn)
  return { hoverDuty = gn.hoverDuty, alt = gn.alt, pitch = gn.pitch, roll = gn.roll,
    yaw = gn.yaw, sway = gn.sway, surge = gn.surge, heaveMin = gn.heaveMin, heaveMax = gn.heaveMax }
end

local function gains()
  return require("fcs.io.tuningdefaults").get().gains
end

-- Deterministic battery: varied errors, grounded + airborne. dt fixed at 0.05.
-- NOTE: case 1's sp.altitude is explicitly 0 (not absent) because level_flight.lua's alt PID
-- has no "or 0" fallback for sp.altitude (unlike pitch/roll/yaw/sway/surge) -- an absent altitude
-- setpoint errors on nil arithmetic. This keeps case 1's "zero everywhere" intent without
-- touching the untouched scheme file.
local BATTERY = {
  { sp = { altitude=0 }, m = { altitude=0, pitch=0, roll=0, heading=0, yawRate=0, swayPos=0, swayVel=0, surgePos=0, surgeVel=0, onGround=false } },
  { sp = { altitude=5 }, m = { altitude=2, pitch=0.05, roll=-0.03, heading=0.2, yawRate=0.1, swayPos=1, swayVel=0.2, surgePos=-1, surgeVel=-0.1, onGround=false } },
  { sp = { altitude=3, heading=1.0, swayPos=2, surgePos=2 }, m = { altitude=3, pitch=-0.1, roll=0.08, heading=0.5, yawRate=-0.2, swayPos=0, swayVel=-0.3, surgePos=0, surgeVel=0.4, onGround=false } },
  { sp = { altitude=1 }, m = { altitude=1, pitch=0, roll=0, heading=0, yawRate=0, swayPos=0, swayVel=0, surgePos=0, surgeVel=0, onGround=true } },
}

-- Frozen PRECISION per-thruster duties, captured verbatim (tools/capture_precision_golden.lua,
-- pristine pre-flight-modes tree):
--   [1] FL=0.260000000 FR=0.260000000 FRL=0.000000000 FRR=0.000000000 MAIN=0.000000000 RL=0.260000000 RR=0.260000000 YFL=0.000000000 YFR=-0.000000000 YRL=0.000000000 YRR=0.000000000
--   [2] FL=0.319500000 FR=0.313500000 FRL=0.000000000 FRR=0.000000000 MAIN=0.175000000 RL=0.329500000 RR=0.323500000 YFL=0.000000000 YFR=0.540000000 YRL=0.040000000 YRR=0.000000000
--   [3] FL=0.262000000 FR=0.278000000 FRL=0.000000000 FRR=0.000000000 MAIN=0.200000000 RL=0.242000000 RR=0.258000000 YFL=1.000000000 YFR=0.000000000 YRL=0.000000000 YRR=0.200000000
--   [4] FL=0.260000000 FR=0.260000000 FRL=0.000000000 FRR=0.000000000 MAIN=0.000000000 RL=0.260000000 RR=0.260000000 YFL=0.000000000 YFR=-0.000000000 YRL=0.000000000 YRR=0.000000000
local EXPECT = {
  [1] = { FL=0.260000000, FR=0.260000000, FRL=0.000000000, FRR=0.000000000, MAIN=0.000000000,
          RL=0.260000000, RR=0.260000000, YFL=0.000000000, YFR=-0.000000000, YRL=0.000000000, YRR=0.000000000 },
  [2] = { FL=0.319500000, FR=0.313500000, FRL=0.000000000, FRR=0.000000000, MAIN=0.175000000,
          RL=0.329500000, RR=0.323500000, YFL=0.000000000, YFR=0.540000000, YRL=0.040000000, YRR=0.000000000 },
  [3] = { FL=0.262000000, FR=0.278000000, FRL=0.000000000, FRR=0.000000000, MAIN=0.200000000,
          RL=0.242000000, RR=0.258000000, YFL=1.000000000, YFR=0.000000000, YRL=0.000000000, YRR=0.200000000 },
  [4] = { FL=0.260000000, FR=0.260000000, FRL=0.000000000, FRR=0.000000000, MAIN=0.000000000,
          RL=0.260000000, RR=0.260000000, YFL=0.000000000, YFR=-0.000000000, YRL=0.000000000, YRR=0.000000000 },
}

return { BATTERY = BATTERY, EXPECT = EXPECT, schemeCfg = function() return schemeCfg(gains()) end, gains = gains }
