-- ui/basalt/regions/fcs.lua
-- FCS region screens for the merged flight page (bottom region). Two screens:
--   fcs_main   : [FCS][GND][PARAMS] color-switches, two INDEPENDENT exclusive chip groups -- the
--                flight-mode selector (PRE/MAN/CRU/LDG/DRN, radio on state.flightMode) and the
--                master/coupling selector (CPL/DCPL, radio on state.masterMode; a craft can be, e.g.,
--                CRUISE+CPL simultaneously) -- and a live auto-trim toggle keyed off masterMode --
--                all laid out with ui.basalt.btnfit.grid (common per-group width, each row
--                independently centered) instead of manual column splitting (ui.panels.fcs's
--                MODES/MODE_LABEL/modeActive + MASTERS/MASTER_LABEL/masterActive/action/trimLabel/
--                trimActive -- same shared contract Task 12's standalone FCS page selector and its
--                trim child button use).
--   fcs_params : the six status lines (MODE/ALT/VSPD/HDG/LOOP/LINK), moved off the main view.
-- Builders match the region contract: (basalt, subFrame, region, runtime) -> { apply(state) }.
-- Command sends mirror ui/basalt/pages/fcs.lua exactly. No render-path peripheral polling.
local Switch    = require("ui.basalt.switchbtn")
local FcsPanel  = require("ui.panels.fcs")
local P         = require("ui.basalt.params")
local btnfit    = require("ui.basalt.btnfit")
local Gfx       = require("ui.basalt.instruments.panelgfx")
local Theme     = require("ui.theme")

-- 3-row outlined control button (subpixel rounded border via native addBorder). Recolour the outline
-- with btn:addBorder(colour) on a state change.
local function ctrlButton(frame, x, y, w, text, borderColor)
  local btn = frame:addButton({ x = x, y = y, width = w, height = 3, text = text })
  btn:setBackground(Theme.role("button")); btn:setForeground(Theme.role("font")); btn:addBorder(borderColor)
  return btn
end

-- 2-row mode button: a feedback-coloured CHIP bar over a label button. Returns { chip, label,
-- setChip(colour), setText(t), onClick(fn) } -- onClick fires on both the chip and the label.
local function chipButton(frame, x, y, w, text)
  local chip = frame:addButton({ x = x, y = y, width = w, height = 1, text = "" })
  local label = frame:addButton({ x = x, y = y + 1, width = w, height = 1, text = text })
  label:setBackground(Theme.role("button")); label:setForeground(Theme.role("font"))
  local ctrl = { chip = chip, label = label }
  function ctrl.setChip(color) chip:setBackground(color); return ctrl end
  function ctrl.setText(t) label:setText(t); return ctrl end
  function ctrl.onClick(fn) chip:onClick(fn); label:onClick(fn); return ctrl end
  -- Outline the whole 2-row chip button (missing-FCS blink cue). A nil colour REMOVES the outline --
  -- chips carry none normally, and the chip's bar bg is dynamic (setChip), so colour-matching to "hide"
  -- would corrupt the bar. Actually remove it instead.
  function ctrl.setBorder(color)
    if color then chip:addBorder(color); label:addBorder(color)
    else chip:removeBorder(); label:removeBorder() end
    return ctrl
  end
  return ctrl
end

-- Missing-FCS cue colour for a FLIGHT feedback button's OUTLINE: blinks gray (inert) <-> red (off feedback).
local function blinkOutline(phase) return (phase == 1) and colors.red or colors.gray end

local M = {}

-- Border edges the FCS region draws. Stacked in the merged flight page the EMC region above draws
-- the TOP edge, so the default omits it; a standalone single-region host (ui/basalt/pages/fcs.lua)
-- passes opts.edges = a full box to close it. PURE.
M.DEFAULT_EDGES = { top = false, bottom = true, left = true, right = true }
function M._resolveEdges(opts)
  return (opts and opts.edges) or M.DEFAULT_EDGES
end

local FIELD_ORDER = { "MODE", "ALT", "VSPD", "HDG", "LOOP", "LINK" }

-- ===== testable intent seam (no Basalt) =====
-- Toggle engage/ground-safety and send the command, mirroring ui/basalt/pages/fcs.lua's wiring.
-- "fcs": engage when disengaged (blocked while gndSafety), disengage when engaged. "gnd": toggle
-- ground safety. Returns the command effect (or nil when gated/unknown).
function M._onFcs(runtime, id, now)
  local ctx = runtime.rx:latest() or {}
  local effect
  if id == "fcs" then
    effect = FcsPanel.action(ctx.engaged and "disengage" or "engage", ctx)
  elseif id == "gnd" then
    effect = FcsPanel.action("gndSafety", ctx)
  end
  if effect and effect.kind == "command" then
    runtime.links.tel:send(runtime.sender:send(effect.cmd))
  end
  return effect
end

-- Flight-mode selector (Task 13): dispatches FcsPanel.action(id) for a MODES id through the SAME
-- runtime.links.tel:send(runtime.sender:send(cmd)) command path M._onFcs uses above. FcsPanel.action
-- for a mode id returns the RAW { k = "flightMode", id = id } command (no .kind/.cmd wrapper -- see
-- ui/panels/fcs.lua's M.action doc comment), so it needs no ctx and is unwrapped one level before
-- sending -- same unwrap ui/basalt/pages/fcs.lua's M._onButton performs, just addressed through this
-- region's own runtime plumbing instead of that page's.
function M._onMode(runtime, id)
  local effect = FcsPanel.action(id)
  if not effect then return nil end
  local cmd = (effect.kind == "command") and effect.cmd or effect
  if cmd then
    runtime.links.tel:send(runtime.sender:send(cmd))
  end
  return effect
end

-- ===== fcs_main =====
-- Row 1 is a blank top margin (matches the merged page's other regions); all content starts at
-- internal y=2. Groups are laid out with btnfit.grid (Task 1): each group gets one common column
-- width (the widest label in that group) and is centered independently within the full frame
-- width (availW=w -- no left/right inset, only the row-1 top margin).
function M.main(basalt, frame, region, runtime, opts)
  local w, h = frame:getSize()

  -- Panel border (low z, behind content): the FCS region draws BOTTOM + LEFT + RIGHT edges; the EMC
  -- region above draws the TOP edge -- together they wrap the whole flight panel with no line between.
  local bg = frame:addImage({ x = 1, y = 1, width = w, height = h }); bg:resizeImage(w, h); bg.set("z", 1)
  Gfx.clear(bg, w, h)
  Gfx.border(bg, w, h, colors.green, M._resolveEdges(opts))

  -- Two orange dividers split the region into 3 sub-regions (inset, not touching the border).
  Gfx.hline(bg, 6, 4, w - 3, colors.orange)
  Gfx.hline(bg, 12, 4, w - 3, colors.orange)

  -- ===== Sub-region 1: FCS controls (3-row outlined). FCS/GND = green/red switch feedback; PARAM
  -- opens the params submenu (blue). Slightly longer PARAM button for its label. =====
  local fcsBtn   = ctrlButton(frame, 4, 2, 8, "FCS", colors.red)
  local gndBtn   = ctrlButton(frame, 14, 2, 8, "GND", colors.red)
  local paramBtn = ctrlButton(frame, 24, 2, 10, "PARAM", colors.blue)
  fcsBtn:onClick(function() M._onFcs(runtime, "fcs", os.epoch("utc")) end)
  gndBtn:onClick(function() M._onFcs(runtime, "gnd", os.epoch("utc")) end)
  paramBtn:onClick(function() region:push("fcs_params") end)

  -- Mode buttons: 2-row chip buttons, all the same size, 3 across. modeCtrls holds every FLIGHT mode
  -- (FcsPanel.MODES) so apply() can colour the active one green (radio across flight modes only).
  -- masterCtrls holds the master/coupling modes (FcsPanel.MASTERS) -- a SEPARATE independent radio
  -- (a craft can be, e.g., CRUISE+CPL simultaneously).
  local col = { 3, 14, 25 }
  local modeCtrls = {}
  local masterCtrls = {}

  -- ===== Sub-region 2: master modes CPL/DCPL + TRIM (one cycling button, orange chip). =====
  for i, id in ipairs({ "CPL", "DCPL" }) do
    local c = chipButton(frame, col[i], 8, 10, FcsPanel.MASTER_LABEL[id] or id)
    c.onClick(function() M._onMode(runtime, id) end)
    masterCtrls[id] = c
  end
  local trimCtrl = chipButton(frame, col[3], 8, 10, "TRIM --")
  trimCtrl.setChip(colors.orange)   -- TRIM is a stateless action (orange), not a radio mode
  trimCtrl.onClick(function()
    local latest = runtime.rx:latest() or {}
    local nextId = ((latest.trimDir or -1) > 0) and "trimDn" or "trimUp"
    M._onMode(runtime, nextId)
  end)

  -- ===== Sub-region 3: flight modes PRE/MAN/CRU + LDG/DRN (real) + TRK (placeholder). =====
  for i, id in ipairs({ "PRECISION", "MAN", "CRUISE" }) do
    local c = chipButton(frame, col[i], 14, 10, FcsPanel.MODE_LABEL[id] or id)
    c.onClick(function() M._onMode(runtime, id) end)
    modeCtrls[id] = c
  end
  for i, id in ipairs({ "DRN", "LDG" }) do
    local c = chipButton(frame, col[i], 17, 10, FcsPanel.MODE_LABEL[id] or id)
    c.onClick(function() M._onMode(runtime, id) end)
    modeCtrls[id] = c
  end
  local placeholders = {}
  placeholders[1] = chipButton(frame, col[3], 17, 10, "TRK")
  placeholders[1].setChip(colors.red)   -- placeholder: TRK wired later via the A/P maneuver executor

  local function apply(state)
    state = state or {}
    -- Missing-FCS cue: when the UI isn't getting FCS signals, the feedback buttons can't be trusted, so
    -- their OUTLINE blinks gray<->red (ui/basalt/fcslink drives state.fcsStale/blinkPhase). Only the
    -- outline changes; the inner chip/label keep their last-known value.
    local blink = state.fcsStale and blinkOutline(state.blinkPhase) or nil
    -- FCS / GND outlines: normally green engaged/on, red disengaged/off; blink when stale.
    fcsBtn:addBorder(blink or (state.engaged and colors.green or colors.red))
    gndBtn:addBorder(blink or (state.gndSafety and colors.green or colors.red))
    -- Mode chips: green for the one active mode, red for the rest (radio across all real modes). Add a
    -- blinking outline when stale; hide it (button-bg colour) otherwise.
    for _, id in ipairs(FcsPanel.MODES) do
      if modeCtrls[id] then  -- only update modes that have UI buttons in this region
        modeCtrls[id].setChip(FcsPanel.modeActive(state, id) and colors.green or colors.red)
        modeCtrls[id].setBorder(blink)   -- nil (healthy) -> removeBorder; a colour (stale) -> blink outline
      end
    end
    -- Master chips: same green/red radio treatment + blink outline, keyed off masterActive/state.masterMode
    -- (a SEPARATE exclusive group from the flight modes above).
    for _, id in ipairs(FcsPanel.MASTERS) do
      if masterCtrls[id] then
        masterCtrls[id].setChip(FcsPanel.masterActive(state, id) and colors.green or colors.red)
        masterCtrls[id].setBorder(blink)
      end
    end
    -- TRIM: orange chip always; label cycles / reads the live direction (or "TRIM --" when inactive).
    trimCtrl.setText(FcsPanel.trimActive(state) and FcsPanel.trimLabel(state) or "TRIM --")
  end

  return {
    id = "fcs_main", apply = apply,
    elements = {
      fcsBtn = fcsBtn, gndBtn = gndBtn, paramBtn = paramBtn,
      modeCtrls = modeCtrls, masterCtrls = masterCtrls, trimCtrl = trimCtrl, placeholders = placeholders,
    },
  }
end

-- ===== fcs_params =====
function M.params(basalt, frame, region, runtime, opts)
  local w, h = frame:getSize()

  -- Background: panel border (BOTTOM+LEFT+RIGHT -- the EMC region above draws the top, so it stays
  -- visible) + two equal orange checkered status boxes filling the region: flight params (top) and
  -- telemetry/UI/autopilot (bottom).
  local bg = frame:addImage({ x = 1, y = 1, width = w, height = h }); bg:resizeImage(w, h); bg.set("z", 1)
  Gfx.clear(bg, w, h)
  Gfx.border(bg, w, h, colors.green, M._resolveEdges(opts))
  Gfx.checkerBox(bg, 3, 2, 34, 8, colors.orange)     -- flight parameters
  Gfx.checkerBox(bg, 3, 10, 34, 16, colors.orange)   -- telemetry / UI / autopilot

  -- One status label. Width guard is re-asserted in apply (aligned/spaced text otherwise wrap-clips
  -- on an unsettled rebuild).
  local W2 = 14
  local L = {}
  local function mk(name, x, y, wd) local lbl = frame:addLabel({ x = x, y = y, width = wd, height = 1, autoSize = false, text = "" }); lbl:setForeground(Theme.role("font")); L[name] = { lbl = lbl, w = wd } end
  -- Top box: FCS MODE full width, then a 2-column grid.
  mk("MODE", 5, 3, 28)
  mk("ALT", 5, 4, W2);    mk("TRUSPD", 20, 4, W2)
  mk("VSPD", 5, 5, W2);   mk("HDG", 20, 5, W2)
  mk("FCS", 5, 6, W2);    mk("GNDSAF", 20, 6, W2)
  mk("PROXWRN", 5, 7, W2); mk("FCSLOOP", 20, 7, W2)
  -- Bottom box: 2-column grid.
  mk("UILOOP", 5, 11, W2);  mk("NAVLOOP", 20, 11, W2)
  mk("APLOOP", 5, 12, W2);  mk("DEVWRN", 20, 12, W2)
  mk("GPSSIG", 5, 13, W2);  mk("APMODE", 20, 13, W2)
  mk("DSKFCS", 5, 14, W2);  mk("DSKNAV", 20, 14, W2)

  -- BACK (blue outlined, 3-row) centred at the bottom.
  local back = ctrlButton(frame, math.max(1, math.floor((w - 10) / 2) + 1), 18, 10, "< BACK", colors.blue)
  back:onClick(function() region:pop() end)

  local function apply(state)
    state = state or {}
    local p = P.values(state)
    local function set(name, label, pad, value)
      local e = L[name]; e.lbl:setWidth(e.w)
      e.lbl:setText(string.format("%-" .. pad .. "s%s", label, value))
    end
    set("MODE", "FCS MODE", 10, p.MODE)
    set("ALT", "ALT", 9, p.ALT)
    set("TRUSPD", "TRU SPD", 9, p.TRUSPD)
    set("VSPD", "VSPD", 9, p.VSPD)
    set("HDG", "HDG", 9, p.HDG)
    set("FCS", "FCS", 9, p.FCS)
    set("GNDSAF", "GND SAF", 9, p.GNDSAF)
    set("PROXWRN", "PROX WRN", 9, p.PROXWRN)
    set("FCSLOOP", "FCS LOOP", 9, p.FCSLOOP)
    set("UILOOP", "UI LOOP", 9, p.UILOOP)
    set("NAVLOOP", "NAV LOOP", 9, p.NAVLOOP)
    set("APLOOP", "A/P LOOP", 9, p.APLOOP)
    set("DEVWRN", "DEV WRN", 9, p.DEVWRN)
    set("GPSSIG", "GPS SIG", 9, p.GPSSIG)
    set("APMODE", "A/P MODE", 9, p.APMODE)
    set("DSKFCS", "DSK FCS", 9, p.DSKFCS)
    set("DSKNAV", "DSK NAV", 9, p.DSKNAV)
  end

  apply({})

  return { id = "fcs_params", apply = apply, elements = { labels = L, back = back } }
end

return M
