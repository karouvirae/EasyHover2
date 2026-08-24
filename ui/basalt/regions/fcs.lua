-- ui/basalt/regions/fcs.lua
-- FCS region screens for the merged flight page (bottom region). Two screens:
--   fcs_main   : [FCS][GND][PARAMS] color-switches, the 5-mode (PRE/MAN/CRU/CPL/DCPL) selector,
--                and a live auto-trim toggle -- all laid out with ui.basalt.btnfit.grid (common
--                per-group width, each row independently centered) instead of manual column
--                splitting (ui.panels.fcs's MODES/MODE_LABEL/action/modeActive/trimLabel/
--                trimActive -- same shared contract Task 12's standalone FCS page selector and its
--                trim child button use).
--   fcs_params : the six status lines (MODE/ALT/VSPD/HDG/LOOP/LINK), moved off the main view.
-- Builders match the region contract: (basalt, subFrame, region, runtime) -> { apply(state) }.
-- Command sends mirror ui/basalt/pages/fcs.lua exactly. No render-path peripheral polling.
local Switch    = require("ui.basalt.switchbtn")
local FcsPanel  = require("ui.panels.fcs")
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
  return ctrl
end

local M = {}

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
function M.main(basalt, frame, region, runtime)
  local w, h = frame:getSize()

  -- Panel border (low z, behind content): the FCS region draws BOTTOM + LEFT + RIGHT edges; the EMC
  -- region above draws the TOP edge -- together they wrap the whole flight panel with no line between.
  local bg = frame:addImage({ x = 1, y = 1, width = w, height = h }); bg:resizeImage(w, h); bg.set("z", 1)
  Gfx.clear(bg, w, h)
  Gfx.border(bg, w, h, colors.green, { top = false, bottom = true, left = true, right = true })

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

  -- Mode buttons: 2-row chip buttons, all the same size, 3 across. modeCtrls holds every real mode
  -- (FcsPanel.MODES) so apply() can colour the active one green (radio: one active across ALL of
  -- CPL/DCPL + flight modes, per the current FCS contract).
  local col = { 3, 14, 25 }
  local modeCtrls = {}

  -- ===== Sub-region 2: master modes CPL/DCPL + TRIM (one cycling button, orange chip). =====
  for i, id in ipairs({ "CPL", "DCPL" }) do
    local c = chipButton(frame, col[i], 8, 10, FcsPanel.MODE_LABEL[id] or id)
    c.onClick(function() M._onMode(runtime, id) end)
    modeCtrls[id] = c
  end
  local trimCtrl = chipButton(frame, col[3], 8, 10, "TRIM --")
  trimCtrl.setChip(colors.orange)   -- TRIM is a stateless action (orange), not a radio mode
  trimCtrl.onClick(function()
    local latest = runtime.rx:latest() or {}
    local nextId = ((latest.trimDir or -1) > 0) and "trimDn" or "trimUp"
    M._onMode(runtime, nextId)
  end)

  -- ===== Sub-region 3: flight modes PRE/MAN/CRU (real) + DRN/NOL/TRK (placeholders, inactive). =====
  for i, id in ipairs({ "PRECISION", "MAN", "CRUISE" }) do
    local c = chipButton(frame, col[i], 14, 10, FcsPanel.MODE_LABEL[id] or id)
    c.onClick(function() M._onMode(runtime, id) end)
    modeCtrls[id] = c
  end
  local placeholders = {}
  for i, lbl in ipairs({ "DRN", "NOL", "TRK" }) do
    placeholders[i] = chipButton(frame, col[i], 17, 10, lbl)
    placeholders[i].setChip(colors.red)   -- placeholder: always inactive (no wiring yet)
  end

  local function apply(state)
    state = state or {}
    -- FCS / GND outlines: green engaged/on, red disengaged/off.
    fcsBtn:addBorder(state.engaged and colors.green or colors.red)
    gndBtn:addBorder(state.gndSafety and colors.green or colors.red)
    -- Mode chips: green for the one active mode, red for the rest (radio across all real modes).
    for _, id in ipairs(FcsPanel.MODES) do
      modeCtrls[id].setChip(FcsPanel.modeActive(state, id) and colors.green or colors.red)
    end
    -- TRIM: orange chip always; label cycles / reads the live direction (or "TRIM --" when inactive).
    trimCtrl.setText(FcsPanel.trimActive(state) and FcsPanel.trimLabel(state) or "TRIM --")
  end

  return {
    id = "fcs_main", apply = apply,
    elements = {
      fcsBtn = fcsBtn, gndBtn = gndBtn, paramBtn = paramBtn,
      modeCtrls = modeCtrls, trimCtrl = trimCtrl, placeholders = placeholders,
    },
  }
end

-- ===== fcs_params =====
function M.params(basalt, frame, region, runtime)
  local w, h = frame:getSize()
  local iw = math.max(1, w - 2)
  local x = 2

  local pBackGeo = btnfit.grid({ "< BACK" }, { x0 = 1, availW = w, y0 = 2, gap = 1, align = "center" })
  local back = frame:addButton({ x = pBackGeo[1].x, y = 2, width = pBackGeo[1].w, height = 1, text = "< BACK" })
  back:onClick(function() region:pop() end)

  local labels = {}
  for i, name in ipairs(FIELD_ORDER) do
    labels[name] = frame:addLabel({ x = x, y = 3 + i, width = iw, height = 1, autoSize = false, text = name .. " --" })
  end

  local function apply(state)
    state = state or {}
    local values = FcsPanel.fieldValues(state)
    for _, name in ipairs(FIELD_ORDER) do
      labels[name]:setText(name .. " " .. values[name])
    end
  end

  return { id = "fcs_params", apply = apply, elements = { labels = labels, back = back } }
end

return M
