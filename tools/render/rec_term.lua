-- tools/render/rec_term.lua
-- A recording CC:Tweaked terminal: implements the term surface Basalt's render path drives
-- (setCursorPos/blit/write/clear/color/palette) and stores the resulting character-cell grid
-- + any palette overrides, instead of drawing anywhere. Feed it to basalt.createFrame() (via
-- term.redirect) and one basalt.update() to capture EXACTLY what a monitor would show -- the
-- same (glyph + fg-slot + bg-slot) per cell the real GPU renderer consumes. See tools/render.
local M = {}

-- CC colour-value (power of two) -> blit hex digit. Order is the canonical colours table:
-- white=1 -> '0', orange=2 -> '1', ... black=32768 -> 'f'.
local VAL2DIGIT = {}
do
  local order = { 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768 }
  local digits = "0123456789abcdef"
  for i, v in ipairs(order) do VAL2DIGIT[v] = digits:sub(i, i) end
end

local function toHex6(a, b, c)
  if b == nil then
    -- packed 0xRRGGBB
    return string.format("%06x", math.floor(a) % 0x1000000)
  end
  local function q(x) return math.max(0, math.min(255, math.floor((x or 0) * 255 + 0.5))) end
  return string.format("%02x%02x%02x", q(a), q(b), q(c))
end

function M.new(w, h)
  local self = { w = w, h = h, x = 1, y = 1, fg = "0", bg = "f", overrides = {} }
  self.grid = {}
  for row = 1, h do
    local ch, fg, bg = {}, {}, {}
    for col = 1, w do ch[col] = 32; fg[col] = "0"; bg[col] = "f" end
    self.grid[row] = { ch = ch, fg = fg, bg = bg }
  end

  local function put(col, row, byte, fgd, bgd)
    if row < 1 or row > self.h or col < 1 or col > self.w then return end
    local g = self.grid[row]
    g.ch[col] = byte; g.fg[col] = fgd; g.bg[col] = bgd
  end

  function self.blit(text, fgs, bgs)
    text = tostring(text)
    for i = 1, #text do
      put(self.x + i - 1, self.y, text:byte(i), (fgs:sub(i, i) ~= "" and fgs:sub(i, i)) or self.fg,
        (bgs:sub(i, i) ~= "" and bgs:sub(i, i)) or self.bg)
    end
    self.x = self.x + #text
  end

  function self.write(text)
    text = tostring(text)
    for i = 1, #text do put(self.x + i - 1, self.y, text:byte(i), self.fg, self.bg) end
    self.x = self.x + #text
  end

  function self.setCursorPos(x, y) self.x = math.floor(x or 1); self.y = math.floor(y or 1) end
  function self.getCursorPos() return self.x, self.y end
  function self.getSize() return self.w, self.h end

  function self.setTextColor(c) self.fg = VAL2DIGIT[c] or self.fg end
  function self.setTextColour(c) self.fg = VAL2DIGIT[c] or self.fg end
  function self.setBackgroundColor(c) self.bg = VAL2DIGIT[c] or self.bg end
  function self.setBackgroundColour(c) self.bg = VAL2DIGIT[c] or self.bg end

  local function fill(rowFrom, rowTo)
    for row = rowFrom, rowTo do
      local g = self.grid[row]
      for col = 1, self.w do g.ch[col] = 32; g.fg[col] = self.fg; g.bg[col] = self.bg end
    end
  end
  function self.clear() fill(1, self.h) end
  function self.clearLine() if self.y >= 1 and self.y <= self.h then fill(self.y, self.y) end end

  function self.setPaletteColor(idx, a, b, c)
    local d = VAL2DIGIT[idx]; if d then self.overrides[d] = toHex6(a, b, c) end
  end
  self.setPaletteColour = self.setPaletteColor

  -- Harmless surface so any incidental call is a no-op rather than a crash.
  function self.setCursorBlink() end
  function self.isColor() return true end
  function self.isColour() return true end
  function self.getTextScale() return 0.5 end
  function self.setTextScale() end
  function self.scroll() end
  function self.getGraphicsMode() return false end
  function self.setGraphicsMode() end
  function self.getPaletteColor() return 1, 1, 1 end
  self.getPaletteColour = self.getPaletteColor
  function self.nativePaletteColour() return 1, 1, 1 end

  return self
end

return M
