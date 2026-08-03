local t = require("tests.framework")
local Pid = require("fcs.control.pid")
t.test("P term is kp*error", function()
  local p = Pid.new({ kp = 2, ki = 0, kd = 0 })
  t.near(p:update(10, 4, 0.1), 12, 1e-9)   -- 2 * (10-4)
end)
t.test("I accumulates over time", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 0 })
  p:update(1, 0, 0.5); p:update(1, 0, 0.5)     -- err=1 each, dt=0.5 -> i=1.0
  t.near(p:update(1, 0, 0), 1.0, 1e-9)         -- dt=0 adds nothing; output = i
end)
t.test("I clamps to iMax (anti-windup)", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 0, iMax = 0.3 })
  for _ = 1, 100 do p:update(1, 0, 0.1) end
  t.near(p:update(1, 0, 0), 0.3, 1e-9)
end)
t.test("saturated freezes integration", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 0 })
  p:update(1, 0, 0.5)                          -- i = 0.5
  p:update(1, 0, 0.5, true)                    -- saturated: no change
  t.near(p:update(1, 0, 0), 0.5, 1e-9)
end)
