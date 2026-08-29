-- fcs/schemes/drone.lua -- DRONE mode: tilt-to-fly. Full Level loop passthrough: attitude +
-- heading + altitude hold AND the horizontal translate loop (sway/surge stabilize on release).
-- The drone KEYMAP (no translate keys) and the pilot's relax-while-tilting + master drift law
-- decide the horizontal setpoints upstream; the scheme itself no longer forces sway/surge to 0.
-- Exposes the inner attitude PIDs so comAuto ki-scoping (fcs.runtime.flight) still works.
local Level = require("fcs.schemes.level_flight")
local Drone = {}
Drone.__index = Drone
function Drone.new(cfg)
  local inner = Level.new(cfg)
  return setmetatable({ inner = inner, pitchPid = inner.pitchPid, rollPid = inner.rollPid }, Drone)
end
function Drone:reset() self.inner:reset() end
function Drone:update(sp, m, dt, freeze, sat)
  -- Full Level loop: attitude/heading/altitude hold AND the horizontal translate loop, which
  -- stabilizes on release. The drone KEYMAP (no translate keys) and the pilot's relax-while-
  -- tilting + master drift law decide the horizontal setpoints; the scheme no longer forces 0.
  return self.inner:update(sp, m, dt, freeze, sat)
end
return Drone
