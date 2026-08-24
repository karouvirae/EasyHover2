-- ui/basalt/instruments/adi.lua
-- Attitude Director Indicator, drawn per-cell onto a Basalt Image element (a text/fg/bg canvas --
-- release/basalt-full.lua elements/Image.lua: resizeImage + setPixel(x,y,char,fg,bg)). Renders:
--   * a SKY (light blue) / GROUND (brown) filled background, split at a subpixel-accurate horizon,
--   * a solid horizon line + a pitch ladder (5-degree short rungs, 10-degree wider rungs),
--   * a fixed aircraft reference symbol: solid "wing" bars pivoting around a round centre body.
-- Pitch/roll are DEGREES. Roll tilts the horizon + ladder (a shear -- exact enough for the modest
-- bank of a hover craft). Pure of peripherals/os; takes an Image + the numbers + the cell size.
--
-- Subpixel model: each cell is 2 wide x 3 tall teletext subpixels. We address 5 of the 6 (TL,TR,ML,
-- MR,BL) via the 128..159 drawing chars; the 6th (bottom-right) is the inverted pixel and is left as
-- background (a line through it gets a 1-subpixel gap -- invisible in practice).
local M = {}

-- blit hex digits for the palette slots the ADI uses. GND expects the PFD to have set that slot to a
-- real brown (the theme repurposes the default brown slot; see pfd.lua's palette note).
M.SKY   = "3"   -- lightBlue
M.GND   = "c"   -- brown
M.LINE  = "0"   -- white   (horizon + pitch ladder)
M.CRAFT = "d"   -- green   (aircraft reference symbol; default = theme font green, overridable per draw)

M.pxPerDeg = 1.6   -- subpixel rows per degree of pitch (rung spacing)

-- teletext mask bit for a subpixel at (col 0/1, row 0/1/2) within a cell. BR (col1,row2) is the
-- non-addressable inverted pixel -> nil.
local BIT = { [0] = { [0] = 1, [1] = 4, [2] = 16 }, [1] = { [0] = 2, [1] = 8, [2] = false } }

-- Pitch-ladder rungs: 0 = the horizon (full width); multiples of 10 are WIDE, the 5-degree steps
-- between are NARROW. Half-widths are in subpixels; the horizon uses a very large half (full span).
local function rungs(SW)
  local r = { { ang = 0, half = SW } }        -- horizon: full width
  local narrow = math.max(2, math.floor(SW * 0.09))   -- 5-degree rungs: short
  local wide   = math.max(4, math.floor(SW * 0.17))   -- 10-degree rungs: wider
  for a = 5, 20, 5 do
    local half = (a % 10 == 0) and wide or narrow
    r[#r + 1] = { ang = a, half = half }
    r[#r + 1] = { ang = -a, half = half }
  end
  return r
end

-- Draw the ADI into `img` (already resizeImage'd to w x h). `body` selects the centre-body glyph
-- (see M.BODIES); `craft` is the blit-hex colour of the aircraft symbol (defaults to M.CRAFT green).
function M.draw(img, pitch, roll, w, h, body, craft)
  pitch, roll = pitch or 0, roll or 0
  craft = craft or M.CRAFT
  local SW = w * 2
  local scx, scy = SW / 2, (h * 3) / 2
  local tanR = math.tan(math.rad(roll))
  local horizonY = scy + pitch * M.pxPerDeg     -- +pitch (nose up) -> horizon moves DOWN
  local R = rungs(SW)

  -- Is subpixel (sx,sy) ON a rung line? Uses the NEAREST subpixel row to the rung -> a crisp,
  -- 1-subpixel-high line (the horizon + every pitch rung).
  local function onLine(sx, sy)
    local dx = sx - scx
    for _, rg in ipairs(R) do
      local ry = horizonY - rg.ang * M.pxPerDeg + dx * tanR
      if math.floor(ry + 0.5) == sy and math.abs(dx) <= rg.half then return true end
    end
    return false
  end

  -- Pass 1: sky/ground fill + the white horizon/ladder lines (1 subpixel high).
  for cy = 1, h do
    for cx = 1, w do
      local sx0, sy0 = (cx - 1) * 2, (cy - 1) * 3
      local bg = ((sy0 + 1.5) < horizonY + (sx0 + 1 - scx) * tanR) and M.SKY or M.GND
      local mask = 0
      for col = 0, 1 do
        for row = 0, 2 do
          local b = BIT[col][row]
          if b and onLine(sx0 + col, sy0 + row) then mask = mask + b end
        end
      end
      if mask == 0 then img:setPixel(cx, cy, " ", bg, bg)
      else img:setPixel(cx, cy, string.char(128 + mask), M.LINE, bg) end
    end
  end

  -- Pass 2: the FIXED aircraft reference -- solid full-cell "wing" bars on the centre cell-row,
  -- a body gap in the middle, then the round centre body. (No end caps -- the "|"s are dropped.)
  local wingRow = math.floor(h / 2) + 1
  local ccx = math.floor(w / 2)
  local bodyGap = 1                              -- cells left free each side of centre for the body
  local wingOut = math.max(bodyGap + 1, math.floor(w * 0.34))
  for cx = 1, w do
    local d = cx - ccx
    if math.abs(d) > bodyGap and math.abs(d) <= wingOut then
      img:setPixel(cx, wingRow, " ", craft, craft)   -- solid full-cell wing segment
    end
  end
  ;(M.BODIES[body] or M.BODIES.circle)(img, ccx, wingRow, w, h, craft)
end

-- Centre-body options (the user picks one). Each draws over the centre cell(s); fg = craft yellow,
-- bg is left as whatever the fill put there.
local function bgAt(img, x, y) return (img:getBg(x, y) or "f"):sub(1, 1) end
M.BODIES = {
  -- a single filled circle (CC bullet \7 -> a real round dot in the renderer)
  circle = function(img, x, y, w, h, c) img:setPixel(x, y, string.char(7), c, bgAt(img, x, y)) end,
  -- a wider round body: "( )" style, a bracket each side of a centre circle
  ring = function(img, x, y, w, h, c)
    img:setPixel(x - 1, y, "(", c, bgAt(img, x - 1, y))
    img:setPixel(x,     y, string.char(7), c, bgAt(img, x, y))
    img:setPixel(x + 1, y, ")", c, bgAt(img, x + 1, y))
  end,
  -- a solid square body (a full colour cell)
  square = function(img, x, y, w, h, c) img:setPixel(x, y, " ", c, c) end,
  -- a diamond
  diamond = function(img, x, y, w, h, c) img:setPixel(x, y, string.char(4), c, bgAt(img, x, y)) end,
}

return M
