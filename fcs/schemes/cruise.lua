-- fcs/schemes/cruise.lua -- CRUISE mode: PRECISION on every axis except surge, which becomes
-- a held forward-throttle detent (set by the pilot, W up / release holds / S down).
local Level = require("fcs.schemes.level_flight")
local Cruise = {}
Cruise.__index = Cruise
function Cruise.new(cfg) return setmetatable({ inner = Level.new(cfg) }, Cruise) end
function Cruise:reset() self.inner:reset() end
function Cruise:update(sp, m, dt, freeze, sat)
  local d = self.inner:update(sp, m, dt, freeze, sat)
  d.surge = sp.surgeThrottle or 0                  -- held throttle, bypasses the position loop
  return d
end
return Cruise
