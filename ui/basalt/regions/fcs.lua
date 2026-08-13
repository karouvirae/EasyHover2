-- ui/basalt/regions/fcs.lua
-- FCS region screens for the merged flight page (bottom region). Two screens:
--   fcs_main   : [FCS][GND][PARAMS] color-switches + the PRECISION/MAN/CRUISE mode selector
--                (ui.panels.fcs's MODES/action/modeActive -- same shared contract Task 12's
--                standalone FCS page selector uses).
--   fcs_params : the six status lines (MODE/ALT/VSPD/HDG/LOOP/LINK), moved off the main view.
-- Builders match the region contract: (basalt, subFrame, region, runtime) -> { apply(state) }.
-- Command sends mirror ui/basalt/pages/fcs.lua exactly. No render-path peripheral polling.
local Switch    = require("ui.basalt.switchbtn")
local FcsPanel  = require("ui.panels.fcs")

local M = {}

local CTRL = { "fcs", "gnd" }         -- the two toggles (PARAMS is a plain drill button)
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
function M.main(basalt, frame, region, runtime)
  local w, h = frame:getSize()
  local iw = math.max(1, w - 2)
  local x = 2

  -- Row 1: the three control buttons, split across the interior width (last absorbs remainder).
  local ctrlLabels = { fcs = "FCS", gnd = "GND", params = "PARM" }
  local cells = { "fcs", "gnd", "params" }
  local cw = math.max(1, math.floor(iw / #cells))
  local switches = {}
  local px = x
  for i, id in ipairs(cells) do
    local width = (i == #cells) and math.max(1, iw - cw * (#cells - 1)) or cw
    if id == "params" then
      local btn = frame:addButton({ x = px, y = 2, width = width, height = 1, text = ctrlLabels[id] })
      btn:onClick(function() region:push("fcs_params") end)
    else
      local sw = Switch.make(frame, { x = px, y = 2, width = width, height = 1, text = ctrlLabels[id] })
      sw.button:onClick(function() M._onFcs(runtime, id, os.epoch("utc")) end)
      switches[id] = sw
    end
    px = px + width
  end

  -- MODE selector (Task 13): one real switch per FcsPanel.MODES id, side-by-side on the row below
  -- the control row -- same row-splitting shape the old inert placeholder grid used, but now driven
  -- by the shared ui.panels.fcs contract (same MODES/action/modeActive the standalone FCS page's
  -- selector uses, Task 12) so both surfaces read identically. No-optimistic-UI: onClick only SENDS
  -- the command via M._onMode; apply(state) below is the only thing that ever turns a switch green.
  local MODE_ORDER = FcsPanel.MODES
  local modeSwitches = {}
  local mcw = math.max(1, math.floor(iw / #MODE_ORDER))
  local mx = x
  local my = 4
  for i, id in ipairs(MODE_ORDER) do
    local width = (i == #MODE_ORDER) and math.max(1, iw - mcw * (#MODE_ORDER - 1)) or mcw
    local sw = Switch.make(frame, { x = mx, y = my, width = width, height = 1, text = id })
    sw.button:onClick(function() M._onMode(runtime, id) end)
    modeSwitches[id] = sw
    mx = mx + width
  end

  local function apply(state)
    state = state or {}
    switches.fcs.set(state.engaged and "on" or "off")
    switches.gnd.set(state.gndSafety and "on" or "off")
    for _, id in ipairs(MODE_ORDER) do
      modeSwitches[id].set(FcsPanel.modeActive(state, id) and "on" or "off")
    end
  end

  return { id = "fcs_main", apply = apply, elements = { switches = switches, modeSwitches = modeSwitches } }
end

-- ===== fcs_params =====
function M.params(basalt, frame, region, runtime)
  local w, h = frame:getSize()
  local iw = math.max(1, w - 2)
  local x = 2

  local back = frame:addButton({ x = x, y = 2, width = math.min(iw, 8), height = 1, text = "< BACK" })
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
