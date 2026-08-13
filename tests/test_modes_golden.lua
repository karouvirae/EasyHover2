-- tests/test_modes_golden.lua
local t = require("tests.framework")
local Scheme = require("fcs.schemes.level_flight")
local Mixer  = require("fcs.mixer.level_flight")
local golden = require("tests.modes_golden_data")   -- BATTERY + EXPECT, exported below

t.test("PRECISION per-thruster outputs match the frozen golden baseline", function()
  local scheme = Scheme.new(golden.schemeCfg())
  local mixer  = Mixer.new()
  for i, c in ipairs(golden.BATTERY) do
    scheme:reset()
    local duties = mixer:mix(scheme:update(c.sp, c.m, 0.05, c.m.onGround))
    for k, want in pairs(golden.EXPECT[i]) do
      t.near(duties[k], want, 1e-9, string.format("case %d thruster %s", i, k))
    end
  end
end)
