-- ui/basalt/pages/fcs.lua
-- FCS (flight controller status + engage/safety) cockpit page: Basalt port of ui/panels/fcs.lua's
-- ENGAGE / DISENGAGE / GND SAFE controls and status overview, plus (Task 12) a live
-- PRECISION / MAN / CRUISE flight-mode selector. POS HOLD + CLR DAMP are NOT here -- they move to
-- the A/P page (Task 18).
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
local Switch   = require("ui.basalt.switchbtn")

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
--
-- Mode ids (PRECISION/MAN/CRUISE, Task 12): FcsPanel.action(id) returns the RAW flightMode
-- command { k = "flightMode", id = id } (no `.kind`/`.cmd` wrapper -- see ui/panels/fcs.lua's
-- M.action doc comment), so it is sent AS the command itself, through the exact same
-- `runtime.links.tel:send(runtime.sender:send(cmd))` call the wrapped button actions use below --
-- same command path as ENGAGE/DISENGAGE/GND SAFE, just unwrapped one level.
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

  local cmd = (effect.kind == "command") and effect.cmd or effect
  if cmd then
    runtime.links.tel:send(runtime.sender:send(cmd))
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

-- Live flight-mode selector row (Task 12): one switch per FcsPanel.MODES id
-- (PRECISION/MAN/CRUISE), labelled by the mode id itself. Real onClick + apply() wiring -- no
-- longer the disabled ALT HLD/HDG HLD/AUTO placeholders. No-optimistic-UI: green comes ONLY from
-- apply(state) reading the reported state.flightMode via FcsPanel.modeActive, never from the tap.
local MODE_ORDER = FcsPanel.MODES

-- FIELD_ORDER indexes ui.panels.fcs's fieldValues(ctx) table (keyed MODE/ALT/VSPD/HDG/LOOP/LINK).
-- FIELD_LABEL is the ON-SCREEN prefix text for each -- identical to the key except MODE, which
-- shows the derived loop state (NORMAL/GROUND/DAMPED/PARKED) and is relabelled STATE here so it
-- reads distinctly from the new PRECISION/MAN/CRUISE mode selector above (LOOP is already taken --
-- it shows loopHz).
local FIELD_ORDER = { "MODE", "ALT", "VSPD", "HDG", "LOOP", "LINK" }
local FIELD_LABEL = { MODE = "STATE", ALT = "ALT", VSPD = "VSPD", HDG = "HDG", LOOP = "LOOP", LINK = "LINK" }

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
  -- Reserve room below for the mode-selector row (1 line + 1 gap) and the six status Labels.
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

  -- Mode-selector row: one switch per MODE_ORDER id, side-by-side, splitting the interior width
  -- (the last one absorbs any remainder so the row never overshoots iw) -- same row-splitting
  -- pattern the old placeholder row used, now built with ui/basalt/switchbtn.lua's Switch.make so
  -- each one is a real color-state switch (reused the same way ui/basalt/regions/fcs.lua's
  -- fcs/gnd switches are built).
  local phTop = y + 1
  local phCount = #MODE_ORDER
  local phW = math.max(1, math.floor(iw / phCount))
  local modeSwitches = {}
  local px = x
  for i, id in ipairs(MODE_ORDER) do
    local width = (i == phCount) and math.max(1, iw - (phW * (phCount - 1))) or phW
    modeSwitches[id] = Switch.make(frame, { x = px, y = phTop, width = width, height = 1, text = FcsPanel.MODE_LABEL[id] or id })
    px = px + width
  end

  local statusTop = phTop + 2
  if statusTop + statusWant - 1 > h then statusTop = math.max(phTop + 1, h - statusWant + 1) end

  local labels = {}
  for i, name in ipairs(FIELD_ORDER) do
    labels[name] = frame:addLabel({ x = x, y = statusTop + i - 1, width = iw, height = 1, autoSize = false, text = FIELD_LABEL[name] .. " --" })
  end

  for _, id in ipairs(CTRL_ORDER) do
    local btn = buttons[id]
    btn:onClick(function()
      M._onButton(runtime, id, os.epoch("utc"))
    end)
  end

  -- Mode switches: tapping dispatches FcsPanel.action(id) through the SAME M._onButton intent seam
  -- (and hence the same runtime.links.tel:send(runtime.sender:send(cmd)) command path) the
  -- ENGAGE/DISENGAGE/GND SAFE buttons above use. No optimistic UI here -- onClick only SENDS the
  -- command; it never flips the switch itself. The switch only turns green once apply(state) below
  -- observes the reported state.flightMode confirming this mode (FcsPanel.modeActive).
  for _, id in ipairs(MODE_ORDER) do
    local sw = modeSwitches[id]
    sw.button:onClick(function()
      M._onButton(runtime, id, os.epoch("utc"))
    end)
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
      labels[name]:setText(FIELD_LABEL[name] .. " " .. values[name])
    end

    local btnStates = FcsPanel.buttonStates(state)
    for _, id in ipairs(CTRL_ORDER) do
      local style = BUTTON_STYLE[btnStates[id]] or BUTTON_STYLE.disabled
      local btn = buttons[id]
      btn:setBackground(colors[style.bg])
      btn:setForeground(colors[style.fg])
      btn:setEnabled(style.enabled)
    end

    -- No-optimistic-UI: green ONLY when the reported state.flightMode confirms this mode.
    for _, id in ipairs(MODE_ORDER) do
      modeSwitches[id].set(FcsPanel.modeActive(state, id) and "on" or "off")
    end
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      engageBtn = buttons.engage, disengageBtn = buttons.disengage, gndSafetyBtn = buttons.gndSafety,
      modeBtns = (function()
        local m = {}
        for _, id in ipairs(MODE_ORDER) do m[id] = modeSwitches[id] and modeSwitches[id].button end
        return m
      end)(),
      stateLabel = labels.MODE, altLabel = labels.ALT, vspdLabel = labels.VSPD,
      hdgLabel = labels.HDG, loopLabel = labels.LOOP, linkLabel = labels.LINK,
    },
  }
end

return M
