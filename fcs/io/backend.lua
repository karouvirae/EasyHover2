local frame = require("fcs.frame")
local Backend = {}
Backend.__index = Backend
function Backend.new(shim, config, clock)
  local self = setmetatable({}, Backend)
  self.shim = shim; self.config = config
  self.clock = clock or function() return os.epoch("utc") end
  self.wrapped = {}                 -- name -> peripheral cache
  self.lastT, self.lastAlt, self.vFilt = nil, nil, 0
  self.swayPos, self.surgePos = 0, 0
  return self
end
function Backend:_periph(name)
  if not name then return nil end
  if self.wrapped[name] == nil then self.wrapped[name] = self.shim.wrap(name) or false end
  return self.wrapped[name] or nil
end
function Backend:setThruster(id, on)
  local p = self:_periph(self.config.thrusters[id])
  if p then p.setThrust(on and 15 or 0) end   -- CC wrapped peripherals take NO self
end
function Backend:liftIds() return frame.LIFT end
function Backend:lateralIds() return frame.LATERAL end
function Backend:mainIds() return frame.MAIN end
function Backend:frontalIds() return frame.FRONTAL end
return Backend
