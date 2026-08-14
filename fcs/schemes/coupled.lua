-- fcs/schemes/coupled.lua -- CPL (opts.decoupled=false) / DCPL (true). Plane-style: the pilot
-- commands throttle/brake/strafe/rudder demands directly; the FCS still stabilizes attitude +
-- altitude + heading. CPL arrests idle horizontal drift via the inner Level translate loop
-- (velocity-damped cushion); DCPL forces idle surge/sway to zero so momentum coasts. Composes the
-- frozen level_flight (no calibrated math copied).
local Level = require("fcs.schemes.level_flight")
local Coupled = {}
Coupled.__index = Coupled
function Coupled.new(cfg, opts)
  return setmetatable({ inner = Level.new(cfg), decoupled = opts and opts.decoupled or false }, Coupled)
end
function Coupled:reset() self.inner:reset() end
function Coupled:update(sp, m, dt, freeze)
  local d = self.inner:update(sp, m, dt, freeze)     -- honors sp.pitch/roll/heading/altitude
  -- Yaw routing: reroute the heading-loop output to the rear-only effector when the pilot used
  -- the rudder keys this tick (sp.yawRear). Otherwise the full differential (d.yaw) stands.
  if sp.yawRear then d.yawRear = d.yaw; d.yaw = 0 end
  -- Surge: pilot demand overrides when active; idle -> CPL keeps the inner cushion, DCPL zeroes.
  if sp.surgeActive then d.surge = sp.surgeCmd or 0
  elseif self.decoupled then d.surge = 0 end
  -- Sway: same rule.
  if sp.swayActive then d.sway = sp.swayCmd or 0
  elseif self.decoupled then d.sway = 0 end
  return d
end
return Coupled
