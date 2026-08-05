local Osc = {}
Osc.__index = Osc
function Osc.new(cfg)
  return setmetatable({ window = cfg.window or 1.0, minChanges = cfg.minChanges or 6,
    t = 0, lastSign = 0, changes = {} }, Osc)
end
function Osc:reset() self.t = 0; self.lastSign = 0; self.changes = {} end
function Osc:update(err, dt)
  self.t = self.t + (dt > 0 and dt or 0)
  local s = err > 0 and 1 or (err < 0 and -1 or 0)
  if s ~= 0 then
    if self.lastSign ~= 0 and s ~= self.lastSign then self.changes[#self.changes + 1] = self.t end
    self.lastSign = s
  end
  local cutoff = self.t - self.window
  while self.changes[1] and self.changes[1] < cutoff do table.remove(self.changes, 1) end
  return #self.changes >= self.minChanges
end
return Osc
