-- ui/basalt/instruments/horizon.lua
-- PURE view-model: the static dashed horizon row for the PFD attitude indicator.
-- No Basalt/peripheral/fs/os access -- returns a plain string. The subpixel glyph is a NAMED
-- constant (M.STYLE.subpixel.pair) the user confirms in-game: CraftOS-PC's font misrepresents
-- extended glyphs (see reference-cct-font-ascii), so tests assert length/structure, never the
-- rendered appearance. ASCII is the safe default.
local M = {}

M.STYLE = {
  ascii    = { pair = "- " },
  subpixel = { pair = "\140 " },   -- placeholder subpixel dash; confirm the glyph in-game
}

-- M.row(w, style) -> string of EXACTLY length w.
function M.row(w, style)
  if type(w) ~= "number" or w < 1 then return "" end
  local s = M.STYLE[style] or M.STYLE.ascii
  local pair = s.pair
  local rep = pair:rep(math.ceil(w / #pair))
  return rep:sub(1, w)
end

return M
