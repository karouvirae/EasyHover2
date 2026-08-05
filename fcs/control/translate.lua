local T = {}
T.__index = T
function T.new(cfg)
  local self = setmetatable({}, T)
  self.kp = cfg.kp or 0; self.ki = cfg.ki or 0; self.kd = cfg.kd or 0
  self.iMin = cfg.iMin or -math.huge; self.iMax = cfg.iMax or math.huge
  self.dtMax = cfg.dtMax or 0.5
  self:reset(); return self
end
function T:reset() self.i = 0 end
function T:update(sp, meas, vel, dt, freeze)
  local err = sp - meas
  if not freeze and dt > 0 and dt <= self.dtMax then
    self.i = self.i + self.ki * err * dt
    if self.i > self.iMax then self.i = self.iMax elseif self.i < self.iMin then self.i = self.iMin end
  end
  return self.kp * err + self.i - self.kd * (vel or 0)
end
return T
