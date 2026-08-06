local t = require("tests.framework")
local Level = require("fcs.actuate.level")

local function fakeBackend()
  local b = { writes = 0, level = {} }
  function b:setThrusterLevel(id, lvl) self.writes = self.writes + 1; self.level[id] = lvl end
  return b
end

t.test("quantizes duty to 0..steps levels (round half up)", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 0, FR = 1, RL = 0.5, RR = 0.2 }, 0)
  t.eq(b.level.FL, 0); t.eq(b.level.FR, 15); t.eq(b.level.RL, 8); t.eq(b.level.RR, 3)
end)
t.test("clamps out-of-range duty", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ H = 1.2, L = -0.1 }, 0)
  t.eq(b.level.H, 15); t.eq(b.level.L, 0)
end)
t.test("writes only when the quantized level changes", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 0.5 }, 0);  t.eq(b.writes, 1)   -- level 8, write #1
  a:apply({ FL = 0.5 }, 0);  t.eq(b.writes, 1)   -- same -> no write
  a:apply({ FL = 0.52 }, 0); t.eq(b.writes, 1)   -- 7.8 -> round 8 -> still 8 -> no write
  a:apply({ FL = 0.6 }, 0);  t.eq(b.writes, 2)   -- 9.0 -> level 9 -> write #2
end)
t.test("state returns the last written level, 0 if unseen", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 1 }, 0)
  t.eq(a:state("FL"), 15); t.eq(a:state("XX"), 0)
end)
