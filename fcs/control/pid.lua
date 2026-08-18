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
  local usable = (dt > 0) and (dt <= self.dtMax) and not saturated
  if usable then
    self.i = self.i + self.ki * err * dt
    if self.i > self.iMax then self.i = self.iMax elseif self.i < self.iMin then self.i = self.iMin end
  end
  local d = 0
  if self.kd ~= 0 then
    if usable and self.lastMeas ~= nil then
      local dMeas = (meas - self.lastMeas) / dt
      local alpha = dt / (self.tauD + dt)
      self.dFilt = self.dFilt + alpha * (dMeas - self.dFilt)
      d = -self.kd * self.dFilt
    end
    -- Track the measurement EVERY tick (even a non-usable dt-gap/saturated one) so the next
    -- usable tick differentiates against the immediately-preceding sample, not a stale one --
    -- otherwise a single lag spike injects a huge derivative kick on recovery.
    self.lastMeas = meas
  end
  return self.kp * err + self.i + d
end
return Pid
