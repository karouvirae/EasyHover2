local t = require("tests.framework")
local Pwm = require("fcs.actuate.pwm")
local function recBackend()
  local b = { writes = 0, on = {} }
  function b:setThruster(id, s) self.writes = self.writes + 1; self.on[id] = s end
  return b
end
t.test("duty 1 always on, duty 0 always off", function()
  local b = recBackend(); local p = Pwm.new({ period = 1, backend = b })
  for _ = 1, 20 do p:apply({ a = 1.0, z = 0.0 }, 0.05) end
  t.truthy(p:state("a") == true); t.truthy(p:state("z") == false)
end)
t.test("equal duties toggle in lockstep (synchronized)", function()
  local b = recBackend(); local p = Pwm.new({ period = 1, backend = b })
  local diff = 0
  for _ = 1, 100 do p:apply({ a = 0.5, c = 0.5 }, 0.03); if p:state("a") ~= p:state("c") then diff = diff + 1 end end
  t.eq(diff, 0)                              -- never disagree => zero moment ripple
end)
t.test("writes happen only on change", function()
  local b = recBackend(); local p = Pwm.new({ period = 1, backend = b })
  for _ = 1, 10 do p:apply({ a = 1.0 }, 0.05) end
  t.eq(b.writes, 1)                          -- turned on once, never re-written
end)
