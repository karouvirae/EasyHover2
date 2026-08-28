-- fcs/schemes/drone.lua -- DRONE mode: tilt-to-fly. Full attitude + heading + altitude hold
-- (Level's loops), but NO translate loop: sway/surge demands are forced to 0 so the dedicated
-- lateral/main effectors stay idle and the craft moves only by vectoring lift through body tilt.
-- Pilot commands pitch/roll directly (policy.tilt) and auto-levels to a stationary hover on
-- release. Exposes the inner attitude PIDs so comAuto ki-scoping (fcs.runtime.flight) still works.
local Level = require("fcs.schemes.level_flight")
local Drone = {}
Drone.__index = Drone
function Drone.new(cfg)
  local inner = Level.new(cfg)
  return setmetatable({ inner = inner, pitchPid = inner.pitchPid, rollPid = inner.rollPid }, Drone)
end
function Drone:reset() self.inner:reset() end
function Drone:update(sp, m, dt, freeze, sat)
  local d = self.inner:update(sp, m, dt, freeze, sat)   -- honors sp.pitch/roll/heading/altitude
  d.sway, d.surge = 0, 0                                 -- no translate loop in drone mode
  return d
end
return Drone
