-- fcs/io/tuningdefaults.lua
-- Committed checkpoint tuning, shared by fcs/tuning.lua and fcs/io/cfgspec.lua
-- so "load defaults" and an absent eh2_tuning.tbl both yield current flight.

local function deep(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = deep(x) end
  return o
end

local DEFAULTS = {
  gains = {
    hoverDuty = 0.26,
    alt   = { kp = 0.02, ki = 0.01, kd = 0.15, tauD = 0.35, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.10, ki = 0, kd = 0.22, tauD = 0.2 },
    roll  = { kp = 0.10, ki = 0, kd = 0.22, tauD = 0.2 },
    yaw   = { kp = 0.95, ki = 0, kd = 1.8 },   -- kd 1.0->1.8: damp the heavy craft's release ring
    sway  = { kp = 0.2, ki = 0, kd = 0.25 },
    surge = { kp = 0.15, ki = 0, kd = 0.25 },
    heaveMin = 0.05,
    heaveMax = 0.85,
  },
  pwmPeriod = 0.3,
  caps = { pitch = 0.2, roll = 0.2, yaw = 0.6, sway = 0.9, surge = 1.0 },
  -- Oscillation detector: a crossing counts only past +/-deadband (rad) so level-flight sensor
  -- dither can't false-trip; a trip auto-releases after calmTime (s) of calm. Per-axis (pitch/roll).
  osc = { window = 1.0, minChanges = 6, deadband = 0.02, calmTime = 1.0 },
  dtMax = 0.5,
  attLimit = 0.6,
  groundIdle = { moveEps = 0.5 },
  profile = { climbHeight = 6, climbRate = 0.6, holdTime = 20, descendRate = 0.7,
              landEps = 0.4, watchdog = 60, overshootMargin = 2, leadCap = 1.0 },
  feel = {
    headingRate    = 2.2,
    leadCapHeading = 0.45,   -- 0.70->0.35 killed the overshoot; nudged to 0.45 for a bit more turn speed
    yawStopLead    = 0.15,   -- s of yaw-rate led into the release capture; LOWER = harder stop

    climbRate      = 4.5,
    leadCapVert    = 8.0,
    surgeSpeed     = 10.0,
    surgeLead      = 20.0,
    swaySpeed      = 5.0,
    swayLead       = 10.0,
  },
}

-- Per-mode tuning: MAN/CRUISE are full, independent records seeded from the base
-- (PRECISION is NOT here -- it reads the top-level tuning, keeping its calibration).
DEFAULTS.modes = {
  MAN = {
    gains = deep(DEFAULTS.gains),
    caps  = { pitch = 0.4, roll = 0.4, yaw = DEFAULTS.caps.yaw, sway = DEFAULTS.caps.sway, surge = DEFAULTS.caps.surge },
    feel  = deep(DEFAULTS.feel),
  },
  CRUISE = {
    gains = deep(DEFAULTS.gains),
    caps  = deep(DEFAULTS.caps),
    feel  = deep(DEFAULTS.feel),
  },
}
-- Tilt feel (MAN): arrow-key tilt, rad and rad/s; keep tiltCap < attLimit (0.6).
DEFAULTS.modes.MAN.feel.tiltRate = 0.8
DEFAULTS.modes.MAN.feel.tiltCap  = 0.40
-- Surge-throttle feel (CRUISE): W ramps up, release holds, S ramps down; 0..1 of MAIN.
DEFAULTS.modes.CRUISE.feel.cruiseThrottleRate = 1.0
DEFAULTS.modes.CRUISE.feel.cruiseThrottleMax  = 1.0

-- CPL/DCPL (plane-style coupled/decoupled): W/S throttle+brake, A/D strafe (sway), arrow-key
-- climb ramp, and a pitch trim so the craft can hold level surge without the pilot fighting the
-- nose-up tendency at speed.
local function coupledFeel()
  local f = deep(DEFAULTS.feel)
  f.throttleRate = 1.0; f.throttleDecay = 1.0; f.brakeGain = 0.5
  f.slowSurgeRate = 0.3; f.strafeRate = 0.3
  f.climbRampTime = 1.0; f.climbBoost = 2.0
  -- Nose-down auto-trim. -1 = nose-down (this craft pitches nose-up on accel). trimGain raised
  -- 0.1->0.35 (~20deg at full throttle) with a dedicated trimCap (~28deg, under attLimit 0.6) so
  -- the differential-only pitch-down can actually counter high surge accel. RETUNE in flight.
  f.trimGain = 0.35; f.trimDir = -1; f.trimCap = 0.5
  return f
end
DEFAULTS.modes.CPL = {
  gains = deep(DEFAULTS.gains),
  -- pitch cap 0.4->0.5 so the mixer's lift-differential torque isn't the nose-down limiter.
  caps  = { pitch = 0.5, roll = 0.4, yaw = DEFAULTS.caps.yaw, sway = DEFAULTS.caps.sway,
            surge = DEFAULTS.caps.surge, yawRear = DEFAULTS.caps.yaw },
  feel  = coupledFeel(),
}
DEFAULTS.modes.DCPL = {
  gains = deep(DEFAULTS.gains),
  caps  = deep(DEFAULTS.modes.CPL.caps),
  feel  = coupledFeel(),
}

local M = {}

function M.get()
  return deep(DEFAULTS)
end

return M
