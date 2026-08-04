local Pid = require("fcs.control.pid")
local Scheme = {}
Scheme.__index = Scheme
function Scheme.new(cfg)
  local self = setmetatable({ hoverDuty = cfg.hoverDuty or 0.5 }, Scheme)
  self.altPid = Pid.new(cfg.alt or {})
  self.pitchPid = Pid.new(cfg.pitch or {})
  self.rollPid = Pid.new(cfg.roll or {})
  return self
end
function Scheme:reset() self.altPid:reset(); self.pitchPid:reset(); self.rollPid:reset() end
function Scheme:update(sp, m, dt)
  return {
    heave = self.hoverDuty + self.altPid:update(sp.altitude, m.altitude, dt),
    pitch = self.pitchPid:update(sp.pitch or 0, m.pitch, dt),
    roll = self.rollPid:update(sp.roll or 0, m.roll, dt),
  }
end
return Scheme
