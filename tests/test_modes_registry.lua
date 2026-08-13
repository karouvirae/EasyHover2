-- tests/test_modes_registry.lua
local t = require("tests.framework")
local Registry = require("fcs.modes.registry")
local golden = require("tests.modes_golden_data")

-- Minimal fake tuning exposing forMode with the golden gains for PRECISION.
-- Dot convention (matches the real fcs.tuning.forMode): forMode(id), not forMode(self, id).
local function fakeTuning()
  local g = golden.gains()
  local base = { gains = g, caps = { pitch=0.2, roll=0.2, yaw=0.6, sway=0.9, surge=1.0 },
    feel = { headingRate=2.2, climbRate=4.5, surgeSpeed=10, swaySpeed=5 } }
  return { forMode = function(id)
    if id == "MAN" then return { gains=g, caps={pitch=0.4,roll=0.4,yaw=0.6,sway=0.9,surge=1.0},
      feel={ tiltRate=0.8, tiltCap=0.4 } } end
    if id == "CRUISE" then return { gains=g, caps=base.caps,
      feel={ cruiseThrottleRate=1.0, cruiseThrottleMax=1.0 } } end
    return base
  end }
end

t.test("registry builds all three modes with correct policy + default", function()
  local reg = Registry.build(fakeTuning())
  t.eq(reg.default, "PRECISION", "default is PRECISION")
  t.eq(#reg.order, 3, "three modes")
  t.eq(reg.byId.MAN.policy.tilt, true, "MAN tilt enabled")
  t.eq(reg.byId.CRUISE.policy.surge, "throttle", "CRUISE surge throttle")
  t.eq(reg.byId.PRECISION.policy.tilt, false, "PRECISION no tilt")
  t.truthy(reg.byId.PRECISION.scheme and reg.byId.PRECISION.mixer, "PRECISION has scheme+mixer")
end)

t.test("PRECISION descriptor reproduces the golden baseline", function()
  local reg = Registry.build(fakeTuning())
  local d = reg.byId.PRECISION
  for i, c in ipairs(golden.BATTERY) do
    d.scheme:reset()
    local duties = d.mixer:mix(d.scheme:update(c.sp, c.m, 0.05, c.m.onGround))
    for k, want in pairs(golden.EXPECT[i]) do
      t.near(duties[k], want, 1e-9, string.format("case %d %s", i, k))
    end
  end
end)
