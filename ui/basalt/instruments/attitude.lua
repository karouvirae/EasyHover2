-- ui/basalt/instruments/attitude.lua
-- PURE view-model: the FPM-style craft symbol (hollow circle + tilting wings) for the PFD
-- attitude indicator. No Basalt/peripheral/fs/os. Returns absolute cells in a w x h box
-- (origin 1,1 top-left; y grows DOWNWARD). Pitch translates the symbol vertically (up = smaller
-- y); bank tilts the wings, cell-stepped (no subpixel). The horizon is a separate static layer
-- (ui/basalt/instruments/horizon.lua); this module draws only the moving craft.
local M = {}

-- Inputs are DEGREES (the PFD page converts the radian sensor feed at its seam). degPerStep=7 with
-- maxStep=3 lets bank read cleanly out to ~21deg before saturating; wingSpan=5 (longer wings) makes
-- a given bank far more legible -- the tip deflects over more columns, so the slope is visible.
M.CFG = { degPerRow = 5, degPerStep = 7, maxStep = 3, wingSpan = 5,
          circleCh = "O", wingCh = "-", tipCh = "|" }

local function round(x) return math.floor(x + 0.5) end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

-- Raw magnitude of pitch translation in rows; craftCells applies the up=negative sign.
function M.pitchRows(pitch, cfg)
  cfg = cfg or M.CFG
  return round((pitch or 0) / cfg.degPerRow)
end

function M.bankStep(roll, cfg)
  cfg = cfg or M.CFG
  return clamp(round((roll or 0) / cfg.degPerStep), -cfg.maxStep, cfg.maxStep)
end

function M.craftCells(pitch, roll, w, h, cfg)
  cfg = cfg or M.CFG
  local cells = {}
  local cx = math.ceil(w / 2)
  local cy = math.ceil(h / 2) - M.pitchRows(pitch, cfg)   -- pitch up -> smaller y
  local step = M.bankStep(roll, cfg)

  local function put(x, y, ch)
    if x >= 1 and x <= w and y >= 1 and y <= h then
      cells[#cells + 1] = { x = x, y = y, ch = ch }
    end
  end

  put(cx, cy, cfg.circleCh)

  -- Each wing: `wingSpan` cells out from the circle. The tip rises/falls by `step` rows across
  -- the span (cell-stepped tilt). Right bank (roll > 0, step > 0) lowers the RIGHT tip.
  for side = -1, 1, 2 do                          -- -1 left, +1 right
    local tipDy = side * step                      -- right tip down under right bank
    for i = 1, cfg.wingSpan do
      local frac = i / cfg.wingSpan
      local dy = round(tipDy * frac)
      local x = cx + side * i
      local ch = (i == cfg.wingSpan) and cfg.tipCh or cfg.wingCh
      put(x, cy + dy, ch)
    end
  end

  return cells
end

return M
