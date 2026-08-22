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

  -- Row 2: FCS / GND / PARM control group (Switch for FCS/GND, plain Button for PARM). Same
  -- onClick wiring as before -- only the geometry now comes from btnfit.grid.
  local CTRL_IDS = { "fcs", "gnd", "params" }
  local ctrlLabels = { "FCS", "GND", "PARM" }
  local ctrlGeo = btnfit.grid(ctrlLabels, { x0 = 1, availW = w, y0 = 2, gap = 1, align = "center" })
  local switches = {}
  local paramsBtn
  for i, id in ipairs(CTRL_IDS) do
    local g = ctrlGeo[i]
    if id == "params" then
      paramsBtn = frame:addButton({ x = g.x, y = g.y, width = g.w, height = 1, text = ctrlLabels[i] })
      paramsBtn:onClick(function() region:push("fcs_params") end)
    else
      local sw = Switch.make(frame, { x = g.x, y = g.y, width = g.w, height = 1, text = ctrlLabels[i] })
      sw.button:onClick(function() M._onFcs(runtime, id, os.epoch("utc")) end)
      switches[id] = sw
    end
  end

  -- MODE selector (Task 13; now a btnfit perRow=3 centered grid instead of a manual 3-then-2
  -- column split): one real switch per FcsPanel.MODES id, driven by the shared ui.panels.fcs
  -- contract (same MODES/MODE_LABEL/action/modeActive the standalone FCS page's selector uses,
  -- Task 12) so both surfaces read identically. No-optimistic-UI: onClick only SENDS the command
  -- via M._onMode; apply(state) below is the only thing that ever turns a switch green.
  local MODE_ORDER = FcsPanel.MODES
  local modeLabels = {}
  for i, id in ipairs(MODE_ORDER) do modeLabels[i] = FcsPanel.MODE_LABEL[id] or id end
  local modeGeo = btnfit.grid(modeLabels, { x0 = 1, availW = w, y0 = 4, perRow = 3, gap = 1, align = "center" })
  local modeSwitches = {}
  for i, id in ipairs(MODE_ORDER) do
    local g = modeGeo[i]
    local sw = Switch.make(frame, { x = g.x, y = g.y, width = g.w, height = 1, text = modeLabels[i] })
    sw.button:onClick(function() M._onMode(runtime, id) end)
    modeSwitches[id] = sw
  end

  -- Live auto-trim toggle (new on this region; ported from ui/basalt/pages/fcs.lua's trimBtn): one
  -- row below the mode grid, centered via btnfit sized off the widest possible label ("TRIM DN"/
  -- "TRIM UP" = 7 chars). onClick reads the latest reported trimDir and sends the OPPOSITE
  -- (trimUp/trimDn) through M._onMode -- the SAME runtime.links.tel:send(runtime.sender:send(cmd))
  -- command path M._onMode already uses for mode ids (FcsPanel.action(id) returns the raw
  -- { kind="command", cmd=... } shape for trimUp/trimDn too, so no extra unwrap is needed here).
  -- No-optimistic-UI: onClick only sends; apply(state) below is the only thing that colors it.
  local trimY = modeGeo[#modeGeo].y + 1
  local trimGeo = btnfit.grid({ "TRIM DN" }, { x0 = 1, availW = w, y0 = trimY, gap = 1, align = "center" })[1]
  local trimBtn = Switch.make(frame, { x = trimGeo.x, y = trimGeo.y, width = trimGeo.w, height = 1, text = "TRIM --" })
  trimBtn.button:onClick(function()
    local latest = runtime.rx:latest() or {}
    local nextId = ((latest.trimDir or -1) > 0) and "trimDn" or "trimUp"
    M._onMode(runtime, nextId)
  end)

  local function apply(state)
    state = state or {}
    switches.fcs.set(state.engaged and "on" or "off")
    switches.gnd.set(state.gndSafety and "on" or "off")
    for _, id in ipairs(MODE_ORDER) do
      modeSwitches[id].set(FcsPanel.modeActive(state, id) and "on" or "off")
    end
    if FcsPanel.trimActive(state) then
      trimBtn.set((state.trimDir or -1) > 0 and "on" or "off")
      trimBtn.button:setText(FcsPanel.trimLabel(state))
    else
      trimBtn.set("disabled")
      trimBtn.button:setText("TRIM --")
    end
  end

  return {
    id = "fcs_main", apply = apply,
    elements = { switches = switches, paramsBtn = paramsBtn, modeSwitches = modeSwitches, trimBtn = trimBtn },
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
