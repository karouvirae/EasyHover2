-- ui/basalt/pages/pfd.lua
-- PFD cockpit page: heading tape (top) + FPM attitude indicator (center) + ALT/SPD readouts
-- (lower-right), all in ONE Basalt frame / ONE apply(). Follows the Task 15 page template
-- (see ui/basalt/pages/ap.lua): exports M.id/M.title and M.build(basalt, frame, runtime, nav)
-- -> { id, apply(state), elements }; apply() only reads the flat instrument state and SETS
-- element text, never polls peripherals (that discipline lives in ui/basalt/app.lua's scheduled
-- loops, off this render-gated path). Rendering follows the codebase row-Label idiom: full-width
-- autoSize=false Labels, updated via :setText().
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build / apply().
local Horizon  = require("ui.basalt.instruments.horizon")
local Tape     = require("ui.basalt.instruments.tape")
local Attitude = require("ui.basalt.instruments.attitude")
local Readout  = require("ui.basalt.instruments.readout")
local Theme    = require("ui.theme")

local M = {}
M.id = "pfd"
M.title = "PFD"

-- Horizon style: "ascii" (safe default) or "subpixel" (confirm the glyph in-game). A future
-- SENS/DISPLAY toggle (Batch B) can flip this; for Batch A it is a build-time constant.
M.HORIZON_STYLE = "ascii"

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()

  -- ---- Heading tape (top): scale row + fixed lubber + heading number ----
  local tapeY = 1
  local tapeLabel = frame:addLabel({ x = 1, y = tapeY, width = w, height = 1, autoSize = false, text = "" })
  local lubCol = Tape.lubberCol(w)
  local lubberMark = frame:addLabel({ x = lubCol, y = tapeY + 1, width = 1, height = 1, autoSize = false, text = "^" })
  local lubberLabel = frame:addLabel({ x = math.max(1, lubCol - 1), y = tapeY + 2, width = 3, height = 1, autoSize = false, text = "" })

  -- ---- Attitude box (center): static horizon layer + moving craft rows ----
  local boxTop = tapeY + 3
  local boxBot = math.max(boxTop + 2, h - 2)  -- leave the bottom 2 rows for ALT/SPD (never invert on a tiny frame)
  local boxH = math.max(3, boxBot - boxTop + 1)
  local horizonStr = Horizon.row(w, M.HORIZON_STYLE)
  local midRow = math.ceil(boxH / 2)          -- horizon at mid-height of the box

  -- One full-width Label per box row (created once). Rows are recomposed in apply(): the horizon
  -- underlay at midRow, the craft cells overlaid. (Repaints are cadence-gated, so recomposing a
  -- static horizon on repaint is negligible -- quantization is the load lever, per spec.)
  local rowLabels = {}
  for r = 1, boxH do
    rowLabels[r] = frame:addLabel({ x = 1, y = boxTop + r - 1, width = w, height = 1, autoSize = false, text = "" })
  end

  -- ---- ALT / SPD readouts (lower-right) ----
  local roW = 12
  local roX = math.max(1, w - roW + 1)
  local altLabel = frame:addLabel({ x = roX, y = h - 1, width = roW, height = 1, autoSize = false, text = "" })
  local spdLabel = frame:addLabel({ x = roX, y = h,     width = roW, height = 1, autoSize = false, text = "" })

  -- ---- Waypoint target cue: bearing bug on the tape scale (created AFTER the tape so it renders on
  -- top) + a TGT readout (lower-left, clear of ALT/SPD). GREEN for a waypoint, BLUE for a route leg.
  local bugLabel = frame:addLabel({ x = lubCol, y = tapeY, width = 1, height = 1, autoSize = false, text = "" })
  local tgtW = math.max(1, roX - 2)
  local tgtLine1 = frame:addLabel({ x = 1, y = h - 1, width = tgtW, height = 1, autoSize = false, text = "" })
  local tgtLine2 = frame:addLabel({ x = 1, y = h,     width = tgtW, height = 1, autoSize = false, text = "" })

  -- Compose a box row string: horizon underlay (only on midRow) with the craft cells overlaid.
  local function composeRow(rowIndex, craftByRow)
    local base = {}
    if rowIndex == midRow then
      for i = 1, w do base[i] = horizonStr:sub(i, i) end
    else
      for i = 1, w do base[i] = " " end
    end
    local overlay = craftByRow[rowIndex]
    if overlay then
      for _, c in ipairs(overlay) do
        if c.x >= 1 and c.x <= w then base[c.x] = c.ch end
      end
    end
    return table.concat(base)
  end

  local function apply(state)
    state = state or {}

    -- Tape. Pass heading through nil-safe: a nil (no fresh nav bearing) renders a blank scale +
    -- "---" lubber rather than a fabricated 000/N. See ui/basalt/instruments/tape.lua.
    tapeLabel:setText(Tape.row(state.heading, w))
    lubberLabel:setText(Tape.lubberLabel(state.heading))

    -- Attitude: craft cells are box-relative; bucket them by row for compositing. The FCS reports
    -- pitch/roll in RADIANS, but the attitude view-model is DEGREE-based (degPerRow/degPerStep), so
    -- convert here at the page seam -- otherwise 0.35 rad (~20 deg bank) is read as 0.35 deg and the
    -- wings never tilt. Mirrors the baroAlt bridge above (contract vs live-cadence units meet here).
    local cells = Attitude.craftCells(math.deg(state.pitch or 0), math.deg(state.roll or 0), w, boxH)
    local byRow = {}
    for _, c in ipairs(cells) do
      byRow[c.y] = byRow[c.y] or {}
      local b = byRow[c.y]; b[#b + 1] = c
    end
    for r = 1, boxH do rowLabels[r]:setText(composeRow(r, byRow)) end

    -- Readouts. The live cockpit cadence state (ui/basalt/app.lua:M.buildState) names barometric
    -- altitude `altitude`, while the Batch-A instrument contract calls it `baroAlt`. Bridge the two
    -- HERE at the page seam so baro-ALT reads live in-game while the pure Readout view-model stays
    -- contract-driven. A future Batch-B feed that sets `baroAlt` directly takes precedence.
    local rstate = state
    if state.baroAlt == nil and state.altitude ~= nil then
      rstate = setmetatable({ baroAlt = state.altitude }, { __index = state })
    end
    altLabel:setText(Readout.alt(rstate))
    spdLabel:setText(Readout.spd(rstate))

    -- Waypoint target cue: bearing bug on the tape + TGT readout. Colored by source (green wpt /
    -- blue route). Hidden when there is no target or no heading to reference.
    local tgt = state.target
    -- Cue colour from config: a route leg (tgt.color=="blue") uses the NAV RT colour, a waypoint uses
    -- the NAV WPT colour. Defaults (rt=blue, wpt=yellow) apply when no runtime/config is present.
    local cc = runtime and runtime.config and runtime.config.colors
    local tgtColor = (tgt and tgt.color == "blue") and Theme.resolve(cc, "rt") or Theme.resolve(cc, "wpt")
    local haveHdg = tgt and type(state.heading) == "number"
    local bugCol = haveHdg and Tape.bugCol(tgt.bearing, state.heading, w) or nil
    if bugCol then
      bugLabel:setX(bugCol); bugLabel:setText("v"); bugLabel:setForeground(tgtColor)
    elseif haveHdg and type(tgt.relBearing) == "number" then
      -- Target is off the visible tape: pin an edge arrow showing which way to turn toward it
      -- (relBearing >= 0 -> to the right). Otherwise the pilot gets no cue for a side target.
      if tgt.relBearing >= 0 then bugLabel:setX(w); bugLabel:setText(">")
      else bugLabel:setX(1); bugLabel:setText("<") end
      bugLabel:setForeground(tgtColor)
    else
      bugLabel:setText("")
    end
    local tr = tgt and Readout.tgt(tgt) or nil
    tgtLine1:setText(tr and tr.line1 or ""); tgtLine1:setForeground(tgtColor)
    tgtLine2:setText(tr and tr.line2 or ""); tgtLine2:setForeground(tgtColor)
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      tapeLabel = tapeLabel,
      lubberMark = lubberMark,
      lubberLabel = lubberLabel,
      rowLabels = rowLabels,
      altLabel = altLabel,
      spdLabel = spdLabel,
      bugLabel = bugLabel,
      tgtLine1 = tgtLine1,
      tgtLine2 = tgtLine2,
    },
  }
end

return M
