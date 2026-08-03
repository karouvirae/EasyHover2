local Pid = {}
Pid.__index = Pid
function Pid.new(cfg)
  local self = setmetatable({}, Pid)
  self.kp = cfg.kp or 0; self.ki = cfg.ki or 0; self.kd = cfg.kd or 0
  self.tauD = cfg.tauD or 0
  self.iMin = cfg.iMin or -math.huge; self.iMax = cfg.iMax or math.huge
  self.dtMax = cfg.dtMax or 0.5
  self:reset()
  return self
end
function Pid:reset() self.i = 0; self.lastMeas = nil; self.dFilt = 0 end
function Pid:update(sp, meas, dt, saturated)
  local err = sp - meas
  if not saturated and dt > 0 then
    self.i = self.i + self.ki * err * dt
    if self.i > self.iMax then self.i = self.iMax elseif self.i < self.iMin then self.i = self.iMin end
  end
  local d = 0
  if self.kd ~= 0 then
    if self.lastMeas ~= nil and dt > 0 then
      local dMeas = (meas - self.lastMeas) / dt
      local alpha = dt / (self.tauD + dt)
      self.dFilt = self.dFilt + alpha * (dMeas - self.dFilt)
      d = -self.kd * self.dFilt
    end
    self.lastMeas = meas
  end
  return self.kp * err + self.i + d
end
return Pid
