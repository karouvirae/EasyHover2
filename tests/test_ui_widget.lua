-- tests/test_ui_widget.lua
local t = require("tests.framework")
local widget = require("ui.widget")

t.test("button.hit is inclusive top-left, exclusive bottom-right", function()
  local r = { x = 2, y = 3, w = 4, h = 2 }   -- covers x in [2,5], y in [3,4]
  t.truthy(widget.button.hit(r, 2, 3), "top-left corner")
  t.truthy(widget.button.hit(r, 5, 4), "bottom-right inclusive cell")
  t.eq(widget.button.hit(r, 6, 3), false, "past right edge")
  t.eq(widget.button.hit(r, 2, 5), false, "past bottom edge")
  t.eq(widget.button.hit(r, 1, 3), false, "left of edge")
end)

t.test("gauge.fill clamps and rounds", function()
  t.eq(widget.gauge.fill(0.0, 10), 0)
  t.eq(widget.gauge.fill(1.0, 10), 10)
  t.eq(widget.gauge.fill(0.5, 10), 5)
  t.eq(widget.gauge.fill(-1, 10), 0, "clamp low")
  t.eq(widget.gauge.fill(2, 10), 10, "clamp high")
  t.eq(widget.gauge.fill(0.44, 10), 4, "round")
end)

t.test("field.format right-aligns value within width", function()
  local s = widget.field.format("ALT", "12.3", 12)
  t.eq(#s, 12, "exact width")
  t.eq(s:sub(1, 3), "ALT", "label at left")
  t.eq(s:sub(-4), "12.3", "value at right")
end)
