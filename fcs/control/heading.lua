local angle = require("fcs.angle")
local H = {}
H.__index = H
function H.new(cfg)
  local self = setmetatable({}, H)
  self.kp = cfg.kp or 0; self.ki = cfg.ki or 0; self.kd = cfg.kd or 0
  self.iMin = cfg.iMin or -math.huge; self.iMax = cfg.iMax or math.huge
  self.dtMax = cfg.dtMax or 0.5
  self:reset(); return self
end
function H:reset() self.i = 0 end
function H:update(sp, meas, yawRate, dt, freeze)
  local err = angle.wrap(sp - meas)
  if not freeze and dt > 0 and dt <= self.dtMax then
    self.i = self.i + self.ki * err * dt
    if self.i > self.iMax then self.i = self.iMax elseif self.i < self.iMin then self.i = self.iMin end
  end
  return self.kp * err + self.i - self.kd * (yawRate or 0)
end
return H
