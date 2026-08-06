local t = require("tests.framework")
local Loop = require("fcs.runtime.loop")
local Mixer = require("fcs.mixer.level_flight")

local function fakeBackend()
  local b = { reads = 0, thrusts = {} }
  b.sensors = function()
    b.reads = b.reads + 1
    return { altitude=0, vSpeed=0, pitch=0, roll=0, heading=0, yawRate=0,
             swayVel=0, surgeVel=0, swayPos=0, surgePos=0, onGround=false }
  end
  b.setThruster = function(id, on) b.thrusts[id] = on end
  return b
end
local function fakeScheme()
  return { reset = function() end,
           update = function() return { heave=0.5, pitch=0, roll=0, yaw=0, sway=0, surge=0 } end }
end
local function fakePwm() return { apply = function() end, state = function() return false end } end
local function build()
  local b = fakeBackend()
  local loop = Loop.new({ scheme = fakeScheme(), mixer = Mixer.new(), pwm = fakePwm(),
    backend = b, dtMax = 0.5 })
  return loop, b
end
local M0 = { altitude=0, vSpeed=0, pitch=0, roll=0, heading=0, yawRate=0,
             swayVel=0, surgeVel=0, swayPos=0, surgePos=0, onGround=false }

t.test("cycle(dt, m) uses the provided measurement (no internal sensor read)", function()
  local loop, b = build(); loop:arm(true)
  loop:cycle(0.1, M0)
  t.eq(b.reads, 0)
end)
t.test("cycle(dt) with no m reads internally (backward compat)", function()
  local loop, b = build(); loop:arm(true)
  loop:cycle(0.1)
  t.eq(b.reads, 1)
end)
t.test("cycle returns diagnostics when armed", function()
  local loop = build(); loop:arm(true)
  local d = loop:cycle(0.1, M0)
  t.eq(d.mode, "NORMAL"); t.truthy(d.demands ~= nil); t.truthy(d.duties.FL ~= nil)
end)
t.test("cycle returns nil demands/duties when disarmed", function()
  local loop = build()
  local d = loop:cycle(0.1, M0)
  t.eq(d.demands, nil); t.eq(d.duties, nil)
end)
