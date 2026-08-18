-- fcs/schemes/manual.lua -- MANUAL mode: PRECISION's full stabilized horizontal loop
-- (position-hold sway/surge, heading-hold, alt-hold) PLUS pilot tilt. Unlike its earlier
-- self it no longer zeroes lateral -- the calibrated Level translate loop stays live so the
-- craft holds station. The "don't fight the bank-drift while tilting" behaviour lives in the
-- pilot (policy.relaxTiltDrift): it relaxes the position setpoints to measured while a tilt
-- key is held, then re-freezes them on release. Composes the frozen level_flight.
local Level = require("fcs.schemes.level_flight")
local Manual = {}
Manual.__index = Manual
function Manual.new(cfg) return setmetatable({ inner = Level.new(cfg) }, Manual) end
function Manual:reset() self.inner:reset() end
function Manual:update(sp, m, dt, freeze)
  -- Full Level loop: honors sp.pitch/roll (tilt), sp.heading, sp.altitude, sp.swayPos/surgePos.
  return self.inner:update(sp, m, dt, freeze)
end
return Manual
