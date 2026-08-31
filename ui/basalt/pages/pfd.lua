-- ui/basalt/pages/pfd.lua
-- PFD cockpit page: heading tape (top) + attitude indicator (center) + SPD / TGT / ALT readouts
-- (bottom). The numbers you scan -- current HEADING, SPD, ALT and the TGT distance -- are drawn as
-- compact 2-cell-tall GAPLESS subpixel digits (ui/basalt/instruments/glyph.lua, via panelgfx's
-- inversion-aware M.cell), so they read at a glance while staying small enough to all fit with the
-- ADI near full height. The tape scale, labels and cardinal marks stay 1-cell. apply() only reads
-- flat instrument state and redraws the canvases; no peripheral access (that lives in app.lua).
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build / apply().
local Tape    = require("ui.basalt.instruments.tape")
local ADI     = require("ui.basalt.instruments.adi")
local Glyph   = require("ui.basalt.instruments.glyph")
local Theme   = require("ui.theme")

local M = {}
M.id = "pfd"
M.title = "PFD"
M.BODY = "circle"
M.GROUND_RGB = 0x6b4a2f

-- Row budget on the 2x2 PFD surface (36x24): tape (3), ADI (17, -11%), big readouts (4).
M.TAPE_H = 3
M.RO_H   = 4

local function round(x) return math.floor(x + 0.5) end
local CARD = { [0] = "N", [90] = "E", [180] = "S", [270] = "W" }
local LABEL_TOL = 1.0    -- a band label goes target-colour only when the bearing is essentially ON it
local ONHDG_TOL = 2.5    -- the current-heading readout goes target-colour when the craft is on course

local function clear(img, w, h)
  for cy = 1, h do for cx = 1, w do img:setPixel(cx, cy, " ", "f", "f") end end
end

-- ---- TAPE: 1-cell scrolling scale with FULL 3-digit band headings (row 1), big 2-cell current
-- heading (rows 2-3). A band label turns target-colour (yellow WPT / blue route) when the target
-- bearing sits exactly on it; otherwise the little v bug marks the between-labels bearing. The big
-- current heading turns target-colour when the craft is on course to the target. ----
local function drawTape(img, w, h, heading, tgt, tgtColor, fontColor)
  clear(img, w, h)
  local cfg = Tape.CFG
  local lub = Tape.lubberCol(w)
  local bearing = tgt and type(tgt.bearing) == "number" and tgt.bearing or nil
  local onLabel = false
  if type(heading) == "number" then
    local half = math.floor(w / 2) * cfg.degPerCell + cfg.labelEvery
    -- ticks every 10 deg
    local baseTick = round(heading / cfg.tickEvery) * cfg.tickEvery
    for a = baseTick - half, baseTick + half, cfg.tickEvery do
      local col = lub + round(Tape.signedDelta(a, heading) / cfg.degPerCell)
      if col >= 1 and col <= w then Glyph.small(img, "'", col, 1, fontColor, colors.black) end
    end
    -- labels every 30 deg: cardinal letter, else the FULL 3-digit heading (rounded to the nearest 10).
    local baseLabel = round(heading / cfg.labelEvery) * cfg.labelEvery
    for a = baseLabel - half, baseLabel + half, cfg.labelEvery do
      local ang = Tape.norm360(a)
      local val = (round(ang / 10) * 10) % 360
      local label = CARD[ang] or string.format("%03d", val)
      local col = lub + round(Tape.signedDelta(a, heading) / cfg.degPerCell)
      local sx = col - math.floor(#label / 2)
      if sx >= 1 and sx + #label - 1 <= w then
        local onIt = bearing and Tape.isOnHeading(bearing, val, LABEL_TOL) or false
        if onIt then onLabel = true end
        Glyph.small(img, label, sx, 1, onIt and tgtColor or fontColor, colors.black)
      end
    end
    -- current heading: target-colour when on course
    local hc = (bearing and Tape.isOnHeading(heading, bearing, ONHDG_TOL)) and tgtColor or fontColor
    Glyph.drawCentered(img, Tape.lubberLabel(heading), lub, 2, hc)
    Glyph.small(img, "^", lub, 1, colors.white, colors.black)
  else
    Glyph.drawCentered(img, "---", lub, 2, fontColor)
  end
  -- bug: the between-labels bearing indicator (or an edge arrow when off the tape). Suppressed when
  -- the bearing sits exactly on a band label -- the coloured label is the indicator there.
  if bearing and type(heading) == "number" and not onLabel then
    local col = Tape.bugCol(bearing, heading, w)
    if col then Glyph.small(img, "v", col, 1, tgtColor, colors.black)
    elseif type(tgt.relBearing) == "number" then
      Glyph.small(img, tgt.relBearing >= 0 and ">" or "<", tgt.relBearing >= 0 and w or 1, 1, tgtColor, colors.black)
    end
  end
end

-- ---- READOUTS: SPD (left) / TGT distance (center) / ALT (right), each a big 2-cell number. ----
local function altPieces(state)
  local src = state.altSource or "Baro"
  if src == "GPS" then
    return (state.gpsFixOk and type(state.gpsAlt) == "number") and tostring(round(state.gpsAlt)) or "---", "GPS"
  end
  local v = state.baroAlt; if v == nil then v = state.altitude end
  return (type(v) == "number") and tostring(round(v)) or "---", "Baro"
end
local function spdPieces(state)
  local src = state.spdSource or "SAS"
  if src == "TAS" then
    return (state.gpsFixOk and type(state.tas) == "number") and tostring(round(state.tas)) or "---", "TAS"
  end
  return (type(state.sas) == "number") and tostring(round(state.sas)) or "---", "SAS"
end

local function drawReadouts(img, w, h, state, tgt, tgtColor, fontColor)
  clear(img, w, h)
  local altV, altU = altPieces(state)
  local spdV, spdU = spdPieces(state)
  -- ALT: label (row 1) + big value (rows 2-3), left.
  Glyph.small(img, "ALT " .. altU, 1, 1, fontColor, colors.black)
  Glyph.draw(img, altV, 1, 2, fontColor)
  -- SPD: label + big value, right-aligned to the edge.
  local spdX = math.max(1, w - Glyph.width(spdV) + 1)
  Glyph.small(img, "SPD " .. spdU, math.max(1, w - #("SPD " .. spdU) + 1), 1, fontColor, colors.black)
  Glyph.draw(img, spdV, spdX, 2, fontColor)
  -- TGT: name (row 1) + big distance (rows 2-3) + alt-delta/arrow (row 4), centered.
  if tgt then
    local cx = 14
    Glyph.small(img, ("TGT " .. tostring(tgt.name or "?")):sub(1, 9), cx, 1, tgtColor, colors.black)
    local dist = (type(tgt.distanceH) == "number") and tostring(round(tgt.distanceH)) or "--"
    local endx = Glyph.draw(img, dist, cx, 2, tgtColor)
    Glyph.small(img, "m", endx, 3, tgtColor, colors.black)
    local line = ""
    if type(tgt.altDelta) == "number" then local a = round(tgt.altDelta); line = (a >= 0 and "+" or "") .. tostring(a) end
    if type(tgt.relBearing) == "number" then
      if tgt.relBearing > 2 then line = line .. " >" elseif tgt.relBearing < -2 then line = line .. " <" end
    end
    if line ~= "" then Glyph.small(img, line, cx, 4, tgtColor, colors.black) end
  end
end

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local tapeH, roH = M.TAPE_H, M.RO_H
  local adiTop = tapeH + 1
  local adiH = math.max(3, h - tapeH - roH)
  local roTop = h - roH + 1

  local tapeImg = frame:addImage({ x = 1, y = 1, width = w, height = tapeH }); tapeImg:resizeImage(w, tapeH)
  local adiImg  = frame:addImage({ x = 1, y = adiTop, width = w, height = adiH }); adiImg:resizeImage(w, adiH)
  local roImg   = frame:addImage({ x = 1, y = roTop, width = w, height = roH }); roImg:resizeImage(w, roH)

  pcall(function()
    local term = frame:getBaseFrame():getTerm()
    term.setPaletteColour(colors.brown, M.GROUND_RGB)
  end)

  local function apply(state)
    state = state or {}
    local fontColor = Theme.role("font")
    local tgt = state.target
    local cc = runtime and runtime.config and runtime.config.colors
    local tgtColor = (tgt and tgt.color == "blue") and Theme.resolve(cc, "rt") or Theme.resolve(cc, "wpt")

    drawTape(tapeImg, w, tapeH, state.heading, tgt, tgtColor, fontColor)
    ADI.draw(adiImg, math.deg(state.pitch or 0), math.deg(state.roll or 0), w, adiH, M.BODY, colors.toBlit(fontColor))
    drawReadouts(roImg, w, roH, state, tgt, tgtColor, fontColor)
  end

  return {
    id = M.id,
    apply = apply,
    elements = { tapeImg = tapeImg, adiImg = adiImg, roImg = roImg },
  }
end

return M
