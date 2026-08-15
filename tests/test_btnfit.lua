local t = require("tests.framework")
local btnfit = require("ui.basalt.btnfit")

t.test("common width = widest label + pad, centered single row", function()
  local g = btnfit.grid({ "FCS", "GND", "PARM" }, { x0 = 1, availW = 14, y0 = 2, gap = 1 })
  t.eq(#g, 3, "three cells")
  t.eq(g[1].w, 4, "cellW = max label (PARM=4)")
  t.eq(g[2].w, 4, "all cells share width")
  -- rowW = 3*4 + 2 = 14; centered in availW 14 -> startX = 1
  t.eq(g[1].x, 1, "first x"); t.eq(g[2].x, 6, "second x"); t.eq(g[3].x, 11, "third x")
  t.eq(g[1].y, 2, "y0 respected")
end)

t.test("wrap 5 into 3-per-row grid, each row centered independently", function()
  local g = btnfit.grid({ "PRE","MAN","CRU","CPL","DCPL" }, { x0 = 1, availW = 14, y0 = 4, perRow = 3, gap = 1 })
  t.eq(g[1].w, 4, "cellW = DCPL(4)")
  t.eq(g[1].y, 4); t.eq(g[3].y, 4, "row 1 y")
  t.eq(g[4].y, 5); t.eq(g[5].y, 5, "row 2 wraps to y+1")
  -- row 2 has 2 cells: rowW = 2*4+1 = 9, centered in 14 -> startX = 1+floor((14-9)/2)=3
  t.eq(g[4].x, 3, "partial row centered, not column-aligned")
end)

t.test("overflow clamps to fit availW (no run-off)", function()
  local g = btnfit.grid({ "AAAA","BBBB","CCCC" }, { x0 = 1, availW = 9, gap = 1 })
  for _, c in ipairs(g) do t.truthy(c.x + c.w - 1 <= 9, "cell stays within availW") end
end)
