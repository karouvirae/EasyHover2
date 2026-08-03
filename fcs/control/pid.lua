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
  return self.kp * err
end
return Pid
