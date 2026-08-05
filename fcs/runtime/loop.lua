local frame = require("fcs.frame")
local envelope = require("fcs.envelope")
local Osc = require("fcs.safety.oscillation")
local Loop = {}
Loop.__index = Loop
function Loop.new(cfg)
  local self = setmetatable({ scheme = cfg.scheme, mixer = cfg.mixer, pwm = cfg.pwm,
    backend = cfg.backend, dtMax = cfg.dtMax or 0.5, sp = {}, armed = false,
    caps = cfg.caps or {}, mode = "NORMAL" }, Loop)
  if cfg.osc then self.osc = Osc.new(cfg.osc) end
  return self
end
function Loop:setpoints(t) self.sp = t end
function Loop:arm(b) self.armed = b and true or false end
function Loop:getMode() return self.mode end
function Loop:clearDamped()
  self.mode = "NORMAL"
  if self.osc then self.osc:reset() end
end
function Loop:cycle(dt)
  if dt < 0 then dt = 0 elseif dt > self.dtMax then dt = self.dtMax end
  local m = self.backend:sensors()
  if not self.armed then
    self.scheme:reset()
    local zeros = {}
    for _, id in ipairs(frame.LIFT) do zeros[id] = 0 end
    for _, id in ipairs(frame.LATERAL) do zeros[id] = 0 end
    for _, id in ipairs(frame.MAIN) do zeros[id] = 0 end
    for _, id in ipairs(frame.FRONTAL) do zeros[id] = 0 end
    self.pwm:apply(zeros, dt)
    return
  end
  local grounded = m.onGround == true
  local demands = self.scheme:update(self.sp, m, dt, grounded)
  if self.mode ~= "DAMPED" then
    self.mode = grounded and "GROUND" or "NORMAL"
  end
  if self.osc then
    if self.osc:update(m.pitch + m.roll, dt) then self.mode = "DAMPED" end
  end
  if self.mode == "DAMPED" then
    demands.pitch, demands.roll, demands.yaw, demands.sway, demands.surge = 0, 0, 0, 0, 0
  end
  demands = envelope.clamp(demands, self.caps)
  local duties = self.mixer:mix(demands)
  self.pwm:apply(duties, dt)
end
return Loop
