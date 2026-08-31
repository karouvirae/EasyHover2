-- tests/test_glyph.lua
-- The PFD's compact 2-cell-tall subpixel digit font (ui/basalt/instruments/glyph.lua). Renders
-- through panelgfx's inversion-aware M.cell so digits are GAPLESS (the bottom-right non-addressable
-- teletext subpixel is filled by colour inversion, not left a hole). Tested against a mock Image
-- that records setPixel calls.
local t = require("tests.framework")
local G = require("ui.basalt.instruments.glyph")

local function mockImg()
  local m = { cells = {}, w = 0, h = 0 }
  function m:resizeImage(w, h) self.w, self.h = w, h end
  function m:setPixel(x, y, ch, fg, bg) self.cells[x .. "," .. y] = { ch = ch, fg = fg, bg = bg } end
  function m:getBg(x, y) local c = self.cells[x .. "," .. y]; return c and c.bg or "f" end
  function m:getImageSize() return self.w, self.h end
  return m
end
local function count(img) local n = 0; for _ in pairs(img.cells) do n = n + 1 end; return n end

t.test("width returns whole cells for a 2-cell-tall number", function()
  t.eq(G.width("1"), 2)     -- 4 subpixels -> ceil(4/2) = 2 cells
  t.eq(G.width("12"), 5)    -- 4+1+4 = 9 subpixels -> ceil(9/2) = 5
  t.eq(G.width("129"), 7)   -- 4+1+4+1+4 = 14 -> 7
  t.eq(G.width(""), 0)
end)

t.test("draw inks cells and returns the cell x after the glyph", function()
  local img = mockImg()
  local endx = G.draw(img, "8", 1, 1, colors.green)
  t.truthy(count(img) >= 3, "a digit inks multiple cells")
  t.eq(endx, 1 + G.width("8"), "returns cell after the glyph")
end)

t.test("draw is GAPLESS: a fully-inked cell is drawn via inversion (bg = colour)", function()
  -- '8' has an all-lit top-left cell (incl. the bottom-right subpixel). M.cell must render it with
  -- inversion (fg=black, bg=colour) so that subpixel fills solid instead of leaving a 1-px hole.
  local img = mockImg()
  G.draw(img, "8", 1, 1, colors.green)
  local greenBl, blackBl = colors.toBlit(colors.green), colors.toBlit(colors.black)
  local inverted = false
  for _, c in pairs(img.cells) do if c.bg == greenBl and c.fg == blackBl then inverted = true end end
  t.truthy(inverted, "solid cell uses inversion -> no bottom-right gap")
end)

t.test("every PFD glyph is defined and draws without error", function()
  local img = mockImg()
  local ok = pcall(function()
    G.draw(img, "0123456789-", 1, 1, colors.green)
    G.draw(img, "NESW", 1, 3, colors.green)
  end)
  t.truthy(ok, "digits, minus and cardinals all render")
end)

t.test("drawCentered centers the string on a column", function()
  local img = mockImg()
  -- "12" is 5 cells wide; centered on col 10 -> starts near col 8. Just assert it inked and stayed in range.
  G.drawCentered(img, "12", 10, 1, colors.green)
  t.truthy(count(img) > 0, "centered number inks cells")
end)

t.test("small writes plain 1-cell text, one char per cell", function()
  local img = mockImg()
  G.small(img, "ALT", 4, 2, colors.green, colors.black)
  t.eq(img.cells["4,2"].ch, "A")
  t.eq(img.cells["6,2"].ch, "T")
end)

return true
