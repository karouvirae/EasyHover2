local Pid = require("fcs.control.pid")
local Heading = require("fcs.control.heading")
local Translate = require("fcs.control.translate")
local Scheme = {}
Scheme.__index = Scheme
function Scheme.new(cfg)
  local self = setmetatable({ hoverDuty = cfg.hoverDuty or 0.5 }, Scheme)
  self.altPid = Pid.new(cfg.alt or {})
  self.pitchPid = Pid.new(cfg.pitch or {})
  self.rollPid = Pid.new(cfg.roll or {})
  self.headingPid = Heading.new(cfg.yaw or {})
  self.swayTc = Translate.new(cfg.sway or {})
  self.surgeTc = Translate.new(cfg.surge or {})
  return self
end
function Scheme:reset()
  self.altPid:reset(); self.pitchPid:reset(); self.rollPid:reset(); self.headingPid:reset()
  self.swayTc:reset(); self.surgeTc:reset()
end
function Scheme:update(sp, m, dt, freeze)
  return {
    heave = self.hoverDuty + self.altPid:update(sp.altitude, m.altitude, dt, freeze),
    pitch = self.pitchPid:update(sp.pitch or 0, m.pitch, dt, freeze),
    roll = self.rollPid:update(sp.roll or 0, m.roll, dt, freeze),
    yaw = self.headingPid:update(sp.heading or 0, m.heading or 0, m.yawRate or 0, dt, freeze),
    sway = self.swayTc:update(sp.swayPos or 0, m.swayPos or 0, m.swayVel or 0, dt, freeze),
    surge = self.surgeTc:update(sp.surgePos or 0, m.surgePos or 0, m.surgeVel or 0, dt, freeze),
  }
end
return Scheme
