package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Fuel = require("ui.fuel")

t.test("kindOf detects by method presence", function()
  t.eq(Fuel.kindOf({ getFuelAmountMb = true }), "fluid")
  t.eq(Fuel.kindOf({ tanks = true }), "fluid")
  t.eq(Fuel.kindOf({ list = true }), "inventory")
  t.eq(Fuel.kindOf({ size = true }), "inventory")
  t.eq(Fuel.kindOf({}), "unknown")
end)

t.test("fraction uses capacity when positive", function()
  t.eq(Fuel.fraction({ amount = 50, capacity = 100 }), 0.5)
  t.eq(Fuel.fraction({ amount = 200, capacity = 100 }), 1)   -- clamped
end)

t.test("fraction falls back to empty/full calibration", function()
  t.eq(Fuel.fraction({ amount = 30 }, { empty = 10, full = 50 }), 0.5)
  t.eq(Fuel.fraction({ amount = 5 },  { empty = 10, full = 50 }), 0)  -- clamped low
  t.eq(Fuel.fraction({ amount = 30 }, { empty = 10, full = 10 }), 0)  -- degenerate
end)

t.test("read is pure over an injected reader", function()
  local frac = Fuel.read(function() return 25, 100 end, "inventory", {})
  t.eq(frac, 0.25)
end)
