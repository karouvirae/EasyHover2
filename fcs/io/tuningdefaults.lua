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
    yaw   = { kp = 0.95, ki = 0, kd = 1.0 },
    sway  = { kp = 0.2, ki = 0, kd = 0.25 },
    surge = { kp = 0.15, ki = 0, kd = 0.25 },
    heaveMin = 0.05,
    heaveMax = 0.85,
  },
  pwmPeriod = 0.3,
  caps = { pitch = 0.2, roll = 0.2, yaw = 0.6, sway = 0.9, surge = 1.0 },
  osc = { window = 1.0, minChanges = 6 },
  dtMax = 0.5,
  attLimit = 0.6,
  groundIdle = { moveEps = 0.5 },
  profile = { climbHeight = 6, climbRate = 0.6, holdTime = 20, descendRate = 0.7,
              landEps = 0.4, watchdog = 60, overshootMargin = 2, leadCap = 1.0 },
  feel = {
    headingRate    = 2.2,
    leadCapHeading = 0.70,
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

local M = {}

function M.get()
  return deep(DEFAULTS)
end

return M
