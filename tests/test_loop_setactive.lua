-- tests/test_loop_setactive.lua
local t = require("tests.framework")
local Loop = require("fcs.runtime.loop")

local function recScheme(tag)
  return { tag = tag, reset = function(self) self.wasReset = true end,
    update = function(self, sp, m, dt) return { heave = self.tag, pitch=0, roll=0, yaw=0, sway=0, surge=0 } end }
end

t.test("setActive swaps scheme/mixer/caps and resets the incoming scheme", function()
  local backend = { sensors = function() return { onGround = false } end }
  local s1, s2 = recScheme(0.1), recScheme(0.9)
  local mix = { mix = function(_, d) return { X = d.heave } end }
  local loop = Loop.new({ scheme = s1, mixer = mix, pwm = { apply = function() end },
    backend = backend, caps = { c = 1 } })
  loop:setActive({ scheme = s2, mixer = mix, caps = { c = 2 } })
  t.truthy(s2.wasReset, "incoming scheme reset")
  t.eq(loop.caps.c, 2, "caps swapped")
  loop:arm(true); loop:setpoints({})
  local r = loop:cycle(0.05, { onGround = false })
  t.near(r.duties.X, 0.9, 1e-9, "cycle now uses the new scheme")
end)
