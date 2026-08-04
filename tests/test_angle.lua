local t = require("tests.framework")
local angle = require("fcs.angle")
local PI = math.pi
t.test("wrap leaves small angles unchanged", function() t.near(angle.wrap(0.3), 0.3, 1e-9) end)
t.test("wrap folds just over +pi to just over -pi", function()
  t.near(angle.wrap(PI + 0.1), -PI + 0.1, 1e-9)
end)
t.test("wrap folds a large negative angle", function()
  t.near(angle.wrap(-3 * PI + 0.2), 0.2 - PI, 1e-6)
end)
t.test("shortest error across the wrap is small", function()
  -- heading 0.05 rad, setpoint at -0.05 rad expressed as ~2pi-0.05
  t.near(angle.wrap((2 * PI - 0.05) - 0.05), -0.1, 1e-6)
end)
