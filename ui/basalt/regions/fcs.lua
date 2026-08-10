-- ui/basalt/regions/fcs.lua
-- FCS region screens for the merged flight page (bottom region). Two screens:
--   fcs_main   : [FCS][GND][PARAMS] color-switches + as many [MODE] placeholder switches as fit.
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

  -- MODE placeholder grid: 2 columns, filling the rows below the control row (all inert switches).
  local placeholders = {}
  local pcw = math.max(1, math.floor(iw / 2))
  local py = 4
  local n = 0
  while py <= h - 1 do
    for col = 0, 1 do
      n = n + 1
      local width = (col == 1) and math.max(1, iw - pcw) or (pcw - 1)
      local sw = Switch.make(frame, { x = x + col * pcw, y = py, width = width, height = 1, text = "MODE" })
      placeholders[#placeholders + 1] = sw   -- stays "disabled" (Switch.make constructs inert)
    end
    py = py + 1
  end

  local function apply(state)
    state = state or {}
    switches.fcs.set(state.engaged and "on" or "off")
    switches.gnd.set(state.gndSafety and "on" or "off")
    -- MODE placeholders carry no live state -- they were built inert and stay that way.
  end

  return { id = "fcs_main", apply = apply, elements = { switches = switches, placeholders = placeholders } }
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
