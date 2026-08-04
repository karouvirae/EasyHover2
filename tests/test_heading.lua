local t = require("tests.framework")
local Heading = require("fcs.control.heading")
local PI = math.pi
t.test("commands a right turn for a positive wrapped error", function()
  local h = Heading.new({ kp = 1, ki = 0, kd = 0 })
  t.near(h:update(0.5, 0.0, 0.0, 0.1), 0.5, 1e-9)
end)
t.test("takes the short way across the wrap", function()
  local h = Heading.new({ kp = 1, ki = 0, kd = 0 })
  -- setpoint just below +pi wrap from measurement just above -pi: short error is negative
  local out = h:update(PI - 0.05, -PI + 0.05, 0.0, 0.1)
  t.truthy(out < 0)                       -- turns the short way (left), not +2pi right
end)
t.test("damps proportionally to yaw rate", function()
  local h = Heading.new({ kp = 0, ki = 0, kd = 0.5 })
  t.near(h:update(0, 0, 2.0, 0.1), -1.0, 1e-9)   -- -kd*yawRate
end)
