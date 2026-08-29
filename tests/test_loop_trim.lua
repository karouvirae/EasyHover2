-- tests/test_loop_trim.lua
local t = require("tests.framework")
local Loop = require("fcs.runtime.loop")

-- Minimal fakes: a scheme returning fixed demands, a mixer echoing demands, a no-op backend.
local function fakeScheme(demands)
  return { reset = function() end, update = function()
    local o = {} for k,v in pairs(demands) do o[k]=v end return o end }
end
local function fakeMixer() return { mix = function(_, d) return d end } end
local function fakeBackend() return { sensors = function() return { onGround = false } end } end
local function fakePwm() return { apply = function() end } end

t.test("loop trim: demands.pitch += trimDir*trimGain*demands.surge; surge untouched", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.5, pitch = 0.1, roll = 0, yaw = 0, sway = 0, surge = 0.8 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0.35)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false })
  t.near(r.demands.pitch, 0.1 + (-1) * 0.35 * 0.8, 1e-9, "nose-down trim added to pitch")
  t.eq(r.demands.surge, 0.8, "surge demand unchanged (no braking)")
end)

t.test("loop trim: zero gain is a no-op", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.5, pitch = 0.1, surge = 0.8 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0); lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false })
  t.near(r.demands.pitch, 0.1, 1e-9, "no trim when gain 0")
end)
