-- tests/test_ui_toolkit.lua
local t = require("tests.framework")
local tk = require("ui.toolkit")

t.test("hit is inclusive of the rect box", function()
  local r = { x = 2, y = 3, w = 4, h = 2 }         -- covers x 2..5, y 3..4
  t.eq(tk.hit(r, 2, 3), true)
  t.eq(tk.hit(r, 5, 4), true)
  t.eq(tk.hit(r, 6, 3), false)
  t.eq(tk.hit(r, 2, 5), false)
end)

t.test("gaugeFill is proportional and clamped", function()
  t.eq(tk.gaugeFill(0, 10), 0)
  t.eq(tk.gaugeFill(0.5, 10), 5)
  t.eq(tk.gaugeFill(1, 10), 10)
  t.eq(tk.gaugeFill(2, 10), 10)
  t.eq(tk.gaugeFill(-1, 10), 0)
end)

t.test("fieldRow right-justifies the value within width", function()
  t.eq(tk.fieldRow("ALT", "42", 8), "ALT   42")
  t.eq(#tk.fieldRow("MODE", "NORMAL", 12), 12)
end)

t.test("button carries id/rect/label/state", function()
  local b = tk.button("engage", 1, 1, 10, 3, "ENGAGE", "idle")
  t.eq(b.kind, "button"); t.eq(b.id, "engage")
  t.eq(b.rect.w, 10); t.eq(b.state, "idle")
  t.eq(tk.hit(b.rect, 3, 2), true)
end)
