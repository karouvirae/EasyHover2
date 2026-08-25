-- ui/basalt/instruments/panelgfx.lua
-- Subpixel panel decoration drawn onto a Basalt Image canvas (setPixel x,y,char,fgHex,bgHex):
--   * M.border      -- a panel frame: black / colour line / black, a clean inset rectangle outline
--                      (corners connect properly). `edges` picks which sides; a disabled side lets the
--                      perpendicular lines run to the region edge (so two stacked regions join with no
--                      seam between them).
--   * M.checkerBox  -- a status box with a 2-subpixel-wide CHECKERED (colour/black) border + black
--                      interior (for overlaid text).
-- Every cell is 2x3 teletext subpixels. The bottom-right subpixel is the non-addressable "inverted"
-- pixel, so M.cell draws via colour-inversion whenever the wanted pattern lights BR -- that keeps
-- vertical lines and full cells SOLID (no 1-subpixel gaps).
local M = {}

local BLACK = "f"
local function bl(c) return colors.toBlit(c) end
-- subpixel (col 0/1, row 0/1/2) -> addressable teletext bit (TL1 TR2 ML4 MR8 BL16); BR = "invert".
local ADDR = { [0] = { [0] = 1, [1] = 4, [2] = 16 }, [1] = { [0] = 2, [1] = 8 } }  -- [1][2]=BR omitted

-- Draw one cell from a 6-entry boolean map `g` (keys tl,tr,ml,mr,bl,br = true where `color`). Uses
-- inversion when br is set so the cell stays solid. No-op if nothing is set (leaves prior content).
function M.cell(img, c, r, g, color)
  local col = bl(color)
  local any = g.tl or g.tr or g.ml or g.mr or g.bl or g.br
  if not any then return end
  if g.br then
    -- colour = the OFF pixels (bg=colour); char lights the BLACK pixels (fg=black). BR is OFF -> colour.
    local blackMask = (not g.tl and 1 or 0) + (not g.tr and 2 or 0) + (not g.ml and 4 or 0)
                    + (not g.mr and 8 or 0) + (not g.bl and 16 or 0)
    img:setPixel(c, r, string.char(128 + blackMask), BLACK, col)
  else
    local mask = (g.tl and 1 or 0) + (g.tr and 2 or 0) + (g.ml and 4 or 0) + (g.mr and 8 or 0) + (g.bl and 16 or 0)
    img:setPixel(c, r, string.char(128 + mask), col, BLACK)
  end
end

function M.clear(img, w, h)
  for y = 1, h do for x = 1, w do img:setPixel(x, y, " ", BLACK, BLACK) end end
end

-- A thin horizontal divider line (1 subpixel, on the cell row's middle subrow) across cols x0..x1.
function M.hline(img, y, x0, x1, color)
  local c = bl(color)
  for x = x0, x1 do img:setPixel(x, y, string.char(128 + 4 + 8), c, BLACK) end   -- ML+MR
end

-- Generic: draw whatever subpixels `on(sx,sy)` returns true for, in `color`, over cell rect.
local function paint(img, c0, r0, c1, r1, color, on)
  for r = r0, r1 do
    for c = c0, c1 do
      local sx, sy = (c - 1) * 2, (r - 1) * 3
      M.cell(img, c, r, {
        tl = on(sx, sy),     tr = on(sx + 1, sy),
        ml = on(sx, sy + 1), mr = on(sx + 1, sy + 1),
        bl = on(sx, sy + 2), br = on(sx + 1, sy + 2),
      }, color)
    end
  end
end

-- Panel border: a clean 1-subpixel colour line inset 1 subpixel from the very edge. `edges` picks
-- sides (default all). A disabled top/bottom lets the verticals extend to the region edge so two
-- stacked regions form one continuous frame with no line between them.
function M.border(img, w, h, color, edges)
  edges = edges or { top = true, bottom = true, left = true, right = true }
  local SW, SH = w * 2, h * 3
  local xL, xR, yT, yB = 1, SW - 2, 1, SH - 2
  local vy0 = edges.top and yT or 0            -- verticals span the region edge where a side is open
  local vy1 = edges.bottom and yB or (SH - 1)
  local function on(sx, sy)
    if edges.top and sy == yT and sx >= xL and sx <= xR then return true end
    if edges.bottom and sy == yB and sx >= xL and sx <= xR then return true end
    if edges.left and sx == xL and sy >= vy0 and sy <= vy1 then return true end
    if edges.right and sx == xR and sy >= vy0 and sy <= vy1 then return true end
    return false
  end
  paint(img, 1, 1, w, h, color, on)
end

-- Status box: a 2-subpixel-wide CHECKERED (colour/black) border around cell rect c0..c1 x r0..r1,
-- black interior. Rounded by dropping the outermost corner subpixel.
-- ===== Tiny 4x5 subpixel font, for 2-cell-tall panel titles =====
-- Basalt's BigFont is a fixed ~3-cell-tall font (too dominant on a title strip, no smaller size), so
-- this hand-rolled 5-subpixel-tall font lets a title occupy exactly 2 character rows. Each glyph is 5
-- rows of "#"/" " (variable width). Uppercase only; unknown chars are skipped, space = 3 subpixels.
M.FONT2 = {
  A = { " ## ", "#  #", "####", "#  #", "#  #" },
  B = { "### ", "#  #", "### ", "#  #", "### " },
  C = { "####", "#   ", "#   ", "#   ", "####" },
  D = { "### ", "#  #", "#  #", "#  #", "### " },
  E = { "####", "#   ", "### ", "#   ", "####" },
  F = { "####", "#   ", "### ", "#   ", "#   " },
  G = { "####", "#   ", "# ##", "#  #", "####" },
  H = { "#  #", "#  #", "####", "#  #", "#  #" },
  I = { "###", " # ", " # ", " # ", "###" },
  J = { "####", "   #", "   #", "#  #", "### " },
  K = { "#  #", "# # ", "##  ", "# # ", "#  #" },
  L = { "#   ", "#   ", "#   ", "#   ", "####" },
  M = { "#  #", "####", "####", "#  #", "#  #" },
  N = { "#  #", "## #", "# ##", "#  #", "#  #" },
  O = { "####", "#  #", "#  #", "#  #", "####" },
  P = { "### ", "#  #", "### ", "#   ", "#   " },
  Q = { "####", "#  #", "#  #", "# # ", "## #" },
  R = { "### ", "#  #", "### ", "# # ", "#  #" },
  S = { "####", "#   ", "####", "   #", "####" },
  T = { "###", " # ", " # ", " # ", " # " },
  U = { "#  #", "#  #", "#  #", "#  #", "####" },
  V = { "#  #", "#  #", "#  #", "# # ", " #  " },
  W = { "#  #", "#  #", "####", "####", "#  #" },
  X = { "#  #", " ## ", " ## ", " ## ", "#  #" },
  Y = { "#  #", "#  #", " ## ", " #  ", " #  " },
  Z = { "####", "   #", " ## ", "#   ", "####" },
}
M.FONT2_H = 5

-- Draw `text` (uppercase) centred as a 2-cell-tall title across cols 1..w, in the 2-cell band whose top
-- character row is `topRow`. `color` is a colors.* value. Letters are 1 subpixel apart. Drawn on `img`
-- via M.cell (black bg preserved between glyphs), so it never overwrites unrelated content.
function M.title(img, topRow, w, text, color)
  text = tostring(text):upper()
  local lit, x = {}, 0
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == " " then
      x = x + 3
    else
      local g = M.FONT2[ch]
      if g then
        for r = 1, #g do
          local line = g[r]
          for cx = 1, #line do
            if line:sub(cx, cx) ~= " " then lit[(x + cx - 1) .. "," .. (r - 1)] = true end
          end
        end
        x = x + #g[1] + 1
      end
    end
  end
  local bw = math.max(0, x - 1)              -- total bitmap width (drop the trailing inter-letter gap)
  local ox = math.floor((w * 2 - bw) / 2)    -- centre horizontally in subpixel space
  local oy = (topRow - 1) * 3 + 1            -- one subpixel of top padding inside the 2-cell band
  local function on(dx, dy) return lit[dx .. "," .. dy] == true end
  for r = topRow, topRow + 1 do
    for c = 1, w do
      local sx0, sy0 = (c - 1) * 2, (r - 1) * 3
      M.cell(img, c, r, {
        tl = on(sx0 - ox, sy0 - oy),     tr = on(sx0 + 1 - ox, sy0 - oy),
        ml = on(sx0 - ox, sy0 + 1 - oy), mr = on(sx0 + 1 - ox, sy0 + 1 - oy),
        bl = on(sx0 - ox, sy0 + 2 - oy), br = on(sx0 + 1 - ox, sy0 + 2 - oy),
      }, color)
    end
  end
end

function M.checkerBox(img, c0, r0, c1, r1, color)
  -- Right edge is extended by ONE subpixel (sx1 = c1*2, into the next cell's left column) so the box
  -- is an ODD number of subpixels wide -- an odd width has a single centre column, so the mirrored
  -- checker is symmetric at the corners AND seamless in the middle (an even width forces a double
  -- subpixel at the centre of the top/bottom edges). Paint one extra column for that edge.
  local sx0, sy0 = (c0 - 1) * 2, (r0 - 1) * 3
  local sx1, sy1 = c1 * 2, r1 * 3 - 1
  local function on(sx, sy)
    if sx < sx0 or sx > sx1 or sy < sy0 or sy > sy1 then return false end
    local dx, dy = math.min(sx - sx0, sx1 - sx), math.min(sy - sy0, sy1 - sy)
    local d = math.min(dx, dy)
    if d == 0 and dx == 0 and dy == 0 then return false end  -- rounded corner
    if d <= 1 then return (dx + sy + 1) % 2 == 0 end          -- 2-subpixel mirrored checker
    return false                                             -- interior
  end
  paint(img, c0, r0, c1 + 1, r1, color, on)
end

return M
