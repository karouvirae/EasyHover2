-- ui/basalt/instruments/tape.lua
-- PURE view-model: the scrolling heading tape for the PFD. No Basalt/peripheral/fs/os.
-- The tape scrolls under a FIXED lubber column: each label/tick angle lands at
--   col = lubberCol + round(signedDelta(angle, heading) / degPerCell)
-- so markers step by whole cells as the heading changes (cell-granular interpolated scroll).
local M = {}

M.CFG = { degPerCell = 3, tickEvery = 10, labelEvery = 30, tickCh = "|" }

local CARD = { [0] = "N", [90] = "E", [180] = "S", [270] = "W" }

local function round(x) return math.floor(x + 0.5) end

function M.norm360(deg)
  local d = deg % 360
  if d < 0 then d = d + 360 end
  return d
end

function M.signedDelta(angle, ref)
  return ((angle - ref + 180) % 360) - 180
end

function M.lubberCol(w) return math.ceil(w / 2) end

function M.lubberLabel(heading)
  return string.format("%03d", round(M.norm360(heading)) % 360)
end

-- Write `text` into char-array `cells` starting at column `col` (1-based), clipped to bounds.
local function place(cells, col, text)
  for i = 1, #text do
    local c = col + i - 1
    if c >= 1 and c <= #cells then cells[c] = text:sub(i, i) end
  end
end

function M.row(heading, w, cfg)
  cfg = cfg or M.CFG
  if type(w) ~= "number" or w < 1 then return "" end
  local cells = {}
  for i = 1, w do cells[i] = " " end
  local lub = M.lubberCol(w)
  local halfSpanDeg = math.floor(w / 2) * cfg.degPerCell + cfg.labelEvery

  -- Ticks (every tickEvery deg within the visible span).
  local baseTick = round(heading / cfg.tickEvery) * cfg.tickEvery
  for a = baseTick - halfSpanDeg, baseTick + halfSpanDeg, cfg.tickEvery do
    local col = lub + round(M.signedDelta(a, heading) / cfg.degPerCell)
    place(cells, col, cfg.tickCh)
  end

  -- Labels (every labelEvery deg): cardinal letter, else 2-digit tens (e.g. 330 -> "33").
  local baseLabel = round(heading / cfg.labelEvery) * cfg.labelEvery
  for a = baseLabel - halfSpanDeg, baseLabel + halfSpanDeg, cfg.labelEvery do
    local ang = M.norm360(a)
    local label = CARD[ang] or string.format("%02d", round(ang / 10) % 36)
    local col = lub + round(M.signedDelta(a, heading) / cfg.degPerCell)
    -- Center the label on its column: a 1-char cardinal lands exactly on `col`; a 2-digit tens
    -- label straddles col-1..col so it reads as centred rather than starting at the column.
    place(cells, col - math.floor(#label / 2), label)
  end

  return table.concat(cells)
end

return M
