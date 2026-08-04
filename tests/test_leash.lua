local t = require("tests.framework")
local leash = require("fcs.leash")
t.test("ramps toward the target at the speed limit", function()
  t.near(leash.step(0, 10, 0, 0.1, 2, 100), 0.2, 1e-9)   -- 2 m/s * 0.1s
end)
t.test("snaps to target when within a step", function()
  t.near(leash.step(0, 0.05, 0, 0.1, 2, 100), 0.05, 1e-9)
end)
t.test("clamps to maxLead ahead of position", function()
  -- far target, big speed, but leash caps the setpoint at pos+maxLead
  t.near(leash.step(0, 100, 5, 1.0, 100, 1.5), 6.5, 1e-9)  -- pos 5 + maxLead 1.5
end)
t.test("clamps behind position too", function()
  t.near(leash.step(0, -100, 5, 1.0, 100, 1.5), 3.5, 1e-9)
end)
