local t = require("tests.framework")
local Mixer = require("fcs.mixer.level_flight")

t.test("d.yawRear drives ONLY the rear lateral pair", function()
  local m = Mixer.new()
  local out = m:mix({ heave = 0.3, yawRear = 0.5 })
  -- rear pair responds (one of YRL/YRR is >0 for a given sign; both are >=0 after clamp)
  t.truthy((out.YRL or 0) > 0 or (out.YRR or 0) > 0, "rear pair fires on yawRear")
  t.eq(out.YFL, 0, "front-left untouched by yawRear")
  t.eq(out.YFR, 0, "front-right untouched by yawRear")
end)

t.test("full d.yaw still drives all four laterals (unchanged)", function()
  local m = Mixer.new()
  local out = m:mix({ heave = 0.3, yaw = 0.5 })
  local anyFront = (out.YFL or 0) > 0 or (out.YFR or 0) > 0
  local anyRear  = (out.YRL or 0) > 0 or (out.YRR or 0) > 0
  t.truthy(anyFront and anyRear, "full yaw uses front and rear")
end)

t.test("yawRear nil leaves the existing mix byte-identical", function()
  local m = Mixer.new()
  local a = m:mix({ heave = 0.3, sway = 0.2, yaw = 0.1 })
  local b = m:mix({ heave = 0.3, sway = 0.2, yaw = 0.1, yawRear = 0 })
  for k, v in pairs(a) do t.near(b[k], v, 1e-12, "axis " .. k) end
end)
