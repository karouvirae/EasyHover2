local Pwm = {}
Pwm.__index = Pwm
function Pwm.new(cfg)
  return setmetatable({ period = cfg.period or 0.5, backend = cfg.backend, phase = 0, on = {} }, Pwm)
end
function Pwm:state(id) return self.on[id] == true end
function Pwm:apply(duties, dt)
  if self.period > 0 and dt > 0 then
    self.phase = (self.phase + dt / self.period) % 1
  end
  for id, duty in pairs(duties) do
    local want = duty > self.phase
    if self.on[id] ~= want then
      self.on[id] = want
      self.backend:setThruster(id, want)
    end
  end
end
return Pwm
