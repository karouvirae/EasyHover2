local Pid = require("fcs.control.pid")
local Heading = require("fcs.control.heading")
local Scheme = {}
Scheme.__index = Scheme
function Scheme.new(cfg)
  local self = setmetatable({ hoverDuty = cfg.hoverDuty or 0.5 }, Scheme)
  self.altPid = Pid.new(cfg.alt or {})
  self.pitchPid = Pid.new(cfg.pitch or {})
  self.rollPid = Pid.new(cfg.roll or {})
  self.headingPid = Heading.new(cfg.yaw or {})
  return self
end
function Scheme:reset() self.altPid:reset(); self.pitchPid:reset(); self.rollPid:reset(); self.headingPid:reset() end
function Scheme:update(sp, m, dt)
  return {
    heave = self.hoverDuty + self.altPid:update(sp.altitude, m.altitude, dt),
    pitch = self.pitchPid:update(sp.pitch or 0, m.pitch, dt),
    roll = self.rollPid:update(sp.roll or 0, m.roll, dt),
    yaw = self.headingPid:update(sp.heading or 0, m.heading or 0, m.yawRate or 0, dt),
  }
end
return Scheme
