-- ui/basalt/instruments/glyph.lua
-- Compact 2-cell-tall subpixel number font for the PFD (heading, ALT, SPD, TGT distance). Renders
-- through ui/basalt/instruments/panelgfx.lua's M.cell, which fills the one non-addressable teletext
-- subpixel (bottom-right) via colour inversion -- so the digits are GAPLESS and render identically
-- in game (the same technique as the FLIGHT panel's checkered borders / titles). Each glyph is a
-- 4-wide x 5-tall subpixel bitmap, occupying ~2 cells wide x 2 cells tall. PURE (no peripheral/os/fs).
local PG = require("ui.basalt.instruments.panelgfx")
local M = {}

-- 4-wide x 5-tall bitmaps ("#" = ink subpixel). Character set: 0-9, minus, cardinals N/E/S/W.
local FONT = {
  ["0"] = { "####", "#  #", "#  #", "#  #", "####" },
  ["1"] = { " ## ", "  # ", "  # ", "  # ", "####" },
  ["2"] = { "####", "   #", "####", "#   ", "####" },
  ["3"] = { "####", "   #", " ###", "   #", "####" },
  ["4"] = { "#  #", "#  #", "####", "   #", "   #" },
  ["5"] = { "####", "#   ", "####", "   #", "####" },
  ["6"] = { "####", "#   ", "####", "#  #", "####" },
  ["7"] = { "####", "   #", "  # ", " #  ", " #  " },
  ["8"] = { "####", "#  #", "####", "#  #", "####" },
  ["9"] = { "####", "#  #", "####", "   #", "####" },
  ["-"] = { "    ", "    ", "####", "    ", "    " },
  ["N"] = { "#  #", "## #", "# ##", "#  #", "#  #" },
  ["E"] = { "####", "#   ", "### ", "#   ", "####" },
  ["S"] = { "####", "#   ", "####", "   #", "####" },
  ["W"] = { "#  #", "#  #", "####", "####", "#  #" },
  [" "] = { "    ", "    ", "    ", "    ", "    " },
}

M.GLYPH_SW = 4    -- subpixels wide per glyph
M.GLYPH_H  = 2    -- cells tall per glyph (5 subpixels)
local GAP  = 1    -- subpixel gap between glyphs

-- cells wide for a string
function M.width(text)
  local n = #tostring(text)
  if n == 0 then return 0 end
  return math.ceil((n * (M.GLYPH_SW + GAP) - GAP) / 2)
end

-- Draw `text` as 2-cell-tall gapless subpixel digits, top-left at cell (cx,cy). `color` is a colors.*
-- value. Returns the cell x AFTER the string.
function M.draw(img, text, cx, cy, color)
  text = tostring(text)
  local lit, x = {}, 0
  for i = 1, #text do
    local g = FONT[text:sub(i, i)] or FONT[" "]
    for r = 1, #g do
      local line = g[r]
      for c = 1, #line do
        if line:sub(c, c) == "#" then lit[(x + c - 1) .. "," .. (r - 1)] = true end
      end
    end
    x = x + M.GLYPH_SW + GAP
  end
  local subW = math.max(0, x - GAP)
  local cellsW = math.ceil(subW / 2)
  local ox, oy = (cx - 1) * 2, (cy - 1) * 3
  for r = cy, cy + 1 do
    for c = cx, cx + cellsW - 1 do
      local sx0, sy0 = (c - 1) * 2, (r - 1) * 3
      local function on(dx, dy) return lit[(dx) .. "," .. (dy)] == true end
      PG.cell(img, c, r, {
        tl = on(sx0 - ox,     sy0 - oy),     tr = on(sx0 + 1 - ox, sy0 - oy),
        ml = on(sx0 - ox,     sy0 + 1 - oy), mr = on(sx0 + 1 - ox, sy0 + 1 - oy),
        bl = on(sx0 - ox,     sy0 + 2 - oy), br = on(sx0 + 1 - ox, sy0 + 2 - oy),
      }, color)
    end
  end
  return cx + cellsW
end

function M.drawCentered(img, text, centerX, cy, color)
  M.draw(img, text, math.floor(centerX - M.width(text) / 2 + 0.5), cy, color)
end

-- Normal 1-cell text straight onto the image (small unit labels / tape scale / TGT name). `color` is
-- a colors.* value; `bgColor` optional (defaults to whatever is under the cell, else black).
function M.small(img, text, cx, cy, color, bgColor)
  text = tostring(text)
  local fg = colors.toBlit(color)
  local bg = bgColor and colors.toBlit(bgColor) or nil
  for i = 1, #text do
    local ccx = cx + i - 1
    local b = bg or (img.getBg and (img:getBg(ccx, cy) or "f"):sub(1, 1)) or "f"
    img:setPixel(ccx, cy, text:sub(i, i), fg, b)
  end
end

return M
