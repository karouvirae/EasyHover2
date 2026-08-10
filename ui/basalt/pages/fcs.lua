-- ui/basalt/pages/fcs.lua
-- FCS (flight controller status + engage/safety) cockpit page: Basalt port of ui/panels/fcs.lua's
-- ENGAGE / DISENGAGE / GND SAFE controls and status overview. POS HOLD + CLR DAMP are NOT here --
-- they move to the A/P page (Task 18).
--
-- Follows the Task 15 template EXACTLY (see ui/basalt/pages/emc.lua's header comment for the full
-- Basalt API provenance notes -- not re-derived here): module exports `M.id`, `M.title`, a
-- Basalt-free testable `M._onButton(runtime, id, now)` intent seam, and `M.build(basalt, frame,
-- runtime) -> { id, apply(state), elements }` with an idempotent apply() that only reads `state`
-- (the canonical flat cadence state -- ui/basalt/app.lua:M.buildState) and never polls peripherals.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/M._onButton/the
-- apply() closure, so `require("ui.basalt.pages.fcs")` loads clean headless.
local FcsPanel = require("ui.panels.fcs")

local M = {}
M.id = "fcs"
M.title = "FCS"

-- ===== M._onButton: the TESTABLE intent seam. No Basalt here. =====
--
-- Mirrors ui/main.lua's applyEffect "command" block EXACTLY (kind=="command":
-- telLink:send(sender:send(effect.cmd))), just addressed through `runtime.links.tel` /
-- `runtime.sender` instead of ui/main.lua's module-local telLink/sender. Button INTENT gating
-- (engage blocked while gndSafety is on) goes through ui.panels.fcs's M.action so semantics stay
-- identical to the old terminal-rendered UI.
--
-- ctx only needs the four fields ui.panels.fcs.action() actually reads for engage/disengage/
-- gndSafety -- engaged/gndSafety/positionHold/mode -- read from the latest telemetry snapshot
-- (runtime.rx:latest()), same source ui/basalt/app.lua:M.buildState draws the cadence state from.
function M._onButton(runtime, id, now)
  local latest = runtime.rx:latest() or {}
  local ctx = {
    engaged      = latest.engaged,
    gndSafety    = latest.gndSafety,
    positionHold = latest.positionHold,
    mode         = latest.mode,
  }
  local effect = FcsPanel.action(id, ctx)
  if not effect then return nil end

  if effect.kind == "command" then
    runtime.links.tel:send(runtime.sender:send(effect.cmd))
  end

  return effect
end

-- ===== M.build: construct the element tree =====

local CTRL_ORDER = { "engage", "disengage", "gndSafety" }
local CTRL_LABEL = {
  engage    = "ENGAGE",
  disengage = "DISENGAGE",
  gndSafety = "GND SAFE",
}

-- Row of disabled placeholder MODE buttons -- the future FCS flight modes the user builds next.
-- Visual-only affordances: no onClick, no intent seam, permanently styled disabled.
local PLACEHOLDER_ORDER = { "altHold", "hdgHold", "auto" }
local PLACEHOLDER_LABEL = {
  altHold = "ALT HLD",
  hdgHold = "HDG HLD",
  auto    = "AUTO",
}

local FIELD_ORDER = { "MODE", "ALT", "VSPD", "HDG", "LOOP", "LINK" }

-- state -> Basalt background/foreground/enabled, mirroring ui/toolkit.lua's BUTTON_BG mapping
-- (on/active -> green, off -> red, idle -> gray, disabled -> gray box with dim text) so the
-- cockpit page reads identically to the old panel. Covers every state ui.panels.fcs's
-- buttonStates() can emit for engage (active/disabled/idle), disengage (active/idle), and
-- gndSafety (on/off).
local BUTTON_STYLE = {
  on       = { bg = "green",  fg = "white",     enabled = true  },
  active   = { bg = "green",  fg = "white",     enabled = true  },
  off      = { bg = "red",    fg = "white",     enabled = true  },
  idle     = { bg = "gray",   fg = "white",     enabled = true  },
  disabled = { bg = "gray",   fg = "lightGray", enabled = false },
}

function M.build(basalt, frame, runtime)
  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  -- Three full-width control buttons, stacked -- same composition as emc.lua's engine controls.
  -- Reserve room below for the placeholder MODE row (1 line + 1 gap) and the six status Labels.
  local rows = #CTRL_ORDER
  local ctrlTop = 2
  local statusWant = #FIELD_ORDER
  local reserved = 2 + statusWant
  local ctrlAreaH = h - ctrlTop - reserved
  if ctrlAreaH < rows then ctrlAreaH = rows end
  local btnH = math.floor(ctrlAreaH / rows)
  if btnH < 1 then btnH = 1 end

  local buttons = {}
  local y = ctrlTop
  for _, id in ipairs(CTRL_ORDER) do
    buttons[id] = frame:addButton({ x = x, y = y, width = iw, height = btnH, text = CTRL_LABEL[id] })
    y = y + btnH
  end

  -- Placeholder MODE row: three buttons side-by-side, splitting the interior width (the last one
  -- absorbs any remainder so the row never overshoots iw).
  local phTop = y + 1
  local phCount = #PLACEHOLDER_ORDER
  local phW = math.max(1, math.floor(iw / phCount))
  local placeholders = {}
  local px = x
  for i, id in ipairs(PLACEHOLDER_ORDER) do
    local width = (i == phCount) and math.max(1, iw - (phW * (phCount - 1))) or phW
    placeholders[id] = frame:addButton({ x = px, y = phTop, width = width, height = 1, text = PLACEHOLDER_LABEL[id] })
    px = px + width
  end

  local statusTop = phTop + 2
  if statusTop + statusWant - 1 > h then statusTop = math.max(phTop + 1, h - statusWant + 1) end

  local labels = {}
  for i, name in ipairs(FIELD_ORDER) do
    labels[name] = frame:addLabel({ x = x, y = statusTop + i - 1, width = iw, height = 1, autoSize = false, text = name .. " --" })
  end

  for _, id in ipairs(CTRL_ORDER) do
    local btn = buttons[id]
    btn:onClick(function()
      M._onButton(runtime, id, os.epoch("utc"))
    end)
  end

  -- Placeholders: styled disabled once, at construction -- apply() never touches them (they carry
  -- no live state; a future task wires real FCS flight modes onto this row).
  for _, id in ipairs(PLACEHOLDER_ORDER) do
    local btn = placeholders[id]
    btn:setBackground(colors.gray)
    btn:setForeground(colors.lightGray)
    btn:setEnabled(false)
  end

  -- apply(state): update elements from the canonical flat cadence state. Idempotent -- safe to
  -- call repeatedly; only ever SETS element props, never polls peripherals (that discipline lives
  -- in ui/basalt/app.lua's scheduled loops, off this render-gated path).
  --
  -- ui.panels.fcs's fieldValues()/buttonStates() both read ctx.engaged/gndSafety/positionHold/
  -- mode/altitude/vSpeed/heading/loopHz/linkUp -- the SAME field names the canonical cadence state
  -- already uses (ui/basalt/app.lua:M.buildState), so `state` is passed straight through with no
  -- ctx remapping (unlike emc.lua's engine ctx, which does need remapping).
  local function apply(state)
    state = state or {}

    local values = FcsPanel.fieldValues(state)
    for _, name in ipairs(FIELD_ORDER) do
      labels[name]:setText(name .. " " .. values[name])
    end

    local btnStates = FcsPanel.buttonStates(state)
    for _, id in ipairs(CTRL_ORDER) do
      local style = BUTTON_STYLE[btnStates[id]] or BUTTON_STYLE.disabled
      local btn = buttons[id]
      btn:setBackground(colors[style.bg])
      btn:setForeground(colors[style.fg])
      btn:setEnabled(style.enabled)
    end
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      engageBtn = buttons.engage, disengageBtn = buttons.disengage, gndSafetyBtn = buttons.gndSafety,
      altHoldBtn = placeholders.altHold, hdgHoldBtn = placeholders.hdgHold, autoBtn = placeholders.auto,
      modeLabel = labels.MODE, altLabel = labels.ALT, vspdLabel = labels.VSPD,
      hdgLabel = labels.HDG, loopLabel = labels.LOOP, linkLabel = labels.LINK,
    },
  }
end

return M
