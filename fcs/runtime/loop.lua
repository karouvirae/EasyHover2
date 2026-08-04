local frame = require("fcs.frame")
local Loop = {}
Loop.__index = Loop
function Loop.new(cfg)
  return setmetatable({ scheme = cfg.scheme, mixer = cfg.mixer, pwm = cfg.pwm,
    backend = cfg.backend, dtMax = cfg.dtMax or 0.5, sp = {}, armed = false }, Loop)
end
function Loop:setpoints(t) self.sp = t end
function Loop:arm(b) self.armed = b and true or false end
function Loop:cycle(dt)
  if dt < 0 then dt = 0 elseif dt > self.dtMax then dt = self.dtMax end
  local m = self.backend:sensors()
  if not self.armed then
    self.scheme:reset()
    local zeros = {}
    for _, id in ipairs(frame.LIFT) do zeros[id] = 0 end
    self.pwm:apply(zeros, dt)
    return
  end
  local demands = self.scheme:update(self.sp, m, dt)
  local duties = self.mixer:mix(demands)
  self.pwm:apply(duties, dt)
end
return Loop
