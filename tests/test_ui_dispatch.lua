-- tests/test_ui_dispatch.lua
local t = require("tests.framework")
local dispatch = require("ui.dispatch")

local HT = {
  { id = "engage",     rect = { x = 1, y = 1, w = 8, h = 3 } },
  { id = "gndSafety",  rect = { x = 1, y = 5, w = 8, h = 3 } },
}

t.test("resolve returns the id of the hit rect", function()
  t.eq(dispatch.resolve(HT, 2, 2), "engage")
  t.eq(dispatch.resolve(HT, 3, 6), "gndSafety")
end)

t.test("resolve returns nil when nothing is hit", function()
  t.eq(dispatch.resolve(HT, 20, 20), nil)
end)
