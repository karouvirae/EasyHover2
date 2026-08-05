local SD = {}
SD.__index = SD
function SD.new(cfg)
  return setmetatable({ backend = cfg.backend, acc = {}, on = {} }, SD)
end
function SD:state(id) return self.on[id] == true end
function SD:apply(duties, dt)
  for id, duty in pairs(duties) do
    local a = (self.acc[id] or 0) + (duty or 0) * dt
    local want
    if dt > 0 and a >= dt then want = true; a = a - dt else want = false end
    self.acc[id] = a
    if self.on[id] ~= want then
      self.on[id] = want
      self.backend:setThruster(id, want)
    end
  end
end
return SD
