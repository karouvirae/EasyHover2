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

t.test("read returns the raw amount as its 2nd value", function()
  local _, amount = Fuel.read(function() return 4200, 64000 end, "fluid", {})
  t.eq(amount, 4200, "raw amount surfaced for the merged flight page")
end)

t.test("manualFrac divides by a set max, ignoring device capacity", function()
  t.eq(Fuel.manualFrac(40, 100), 0.4)
  t.eq(Fuel.manualFrac(200, 100), 1, "clamped high")
  t.eq(Fuel.manualFrac(50, 0), 0, "no max -> 0")
  t.eq(Fuel.manualFrac(50, nil), 0, "nil max -> 0")
  t.eq(Fuel.manualFrac(nil, 100), 0, "nil amount -> 0")
end)
