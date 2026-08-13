-- fcs/schemes/manual.lua -- MANUAL mode: stabilized attitude with pilot tilt; horizontal
-- hold relaxed so tilt actually translates the craft. Composes the frozen level_flight.
local Level = require("fcs.schemes.level_flight")
local Manual = {}
Manual.__index = Manual
function Manual.new(cfg) return setmetatable({ inner = Level.new(cfg) }, Manual) end
function Manual:reset() self.inner:reset() end
function Manual:update(sp, m, dt, freeze)
  local d = self.inner:update(sp, m, dt, freeze)   -- honors sp.pitch/sp.roll already
  d.sway, d.surge = 0, 0                            -- no horizontal loop: tilt translates freely
  return d
end
return Manual
