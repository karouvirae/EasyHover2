-- ui/basalt/pages/ap.lua
-- A/P (autopilot) cockpit page: Basalt port of the positionHold + clearDamped controls
-- moved from ui/panels/fcs.lua in Task 16. POS HOLD + CLR DAMP buttons with placeholder
-- modes (ALT HOLD, WAYPOINT, RTB) reserved for future expansion.
--
-- Follows the Task 15 template EXACTLY (see ui/basalt/pages/emc.lua's header comment for the
-- full Basalt API provenance notes -- not re-derived here): module exports `M.id`, `M.title`,
-- a Basalt-free testable `M._onButton(runtime, id, now)` intent seam, and `M.build(basalt,
-- frame, runtime) -> { id, apply(state), elements }` with an idempotent apply() that only
-- reads `state` (the canonical flat cadence state -- ui/basalt/app.lua:M.buildState) and never
-- polls peripherals.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/M._onButton/the
-- apply() closure, so `require("ui.basalt.pages.ap")` loads clean headless.
local FcsPanel = require("ui.panels.fcs")
local Theme    = require("ui.theme")

local M = {}
M.id = "ap"
M.title = "A/P"

-- ===== M._onButton: the TESTABLE intent seam. No Basalt here. =====
--
-- Mirrors ui/main.lua's applyEffect "command" block EXACTLY (kind=="command":
-- telLink:send(sender:send(effect.cmd))), just addressed through `runtime.links.tel` /
-- `runtime.sender` instead of ui/main.lua's module-local telLink/sender. Button INTENT gating
-- and state semantics go through ui.panels.fcs's M.action so semantics stay identical to the
-- old terminal-rendered UI.
--
-- ctx only needs the two fields ui.panels.fcs.action() actually reads for positionHold and
-- clearDamped -- positionHold/mode -- read from the latest telemetry snapshot
-- (runtime.rx:latest()), same source ui/basalt/app.lua:M.buildState draws the cadence state from.
function M._onButton(runtime, id, now)
  local latest = runtime.rx:latest() or {}
  local ctx = {
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

local CTRL_ORDER = { "positionHold", "clearDamped" }
local CTRL_LABEL = {
  positionHold = "POS HOLD",
  clearDamped  = "CLR DAMP",
}

-- Row of disabled placeholder A/P mode buttons -- the future autopilot flight modes the user
-- builds next. Visual-only affordances: no onClick, no intent seam, permanently styled disabled.
local PLACEHOLDER_ORDER = { "altHold", "waypoint", "rtb" }
local PLACEHOLDER_LABEL = {
  altHold  = "ALT HLD",
  waypoint = "WAYPOINT",
  rtb      = "RTB",
}

-- state -> Basalt background/foreground/enabled, mirroring ui/toolkit.lua's BUTTON_BG mapping
-- (on/active -> green, off -> red, idle -> gray, disabled -> gray box with dim text) so the
-- cockpit page reads identically to the old panel. Covers every state ui.panels.fcs's
-- buttonStates() can emit for positionHold (on/off) and clearDamped (active/idle).
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

  -- Two full-width control buttons, stacked -- reserve room below for the placeholder MODE row
  -- (1 line + 1 gap) and an optional status Label.
  local rows = #CTRL_ORDER
  local ctrlTop = 2
  local reserved = 2 + 1
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

  for _, id in ipairs(CTRL_ORDER) do
    local btn = buttons[id]
    btn:onClick(function()
      M._onButton(runtime, id, os.epoch("utc"))
    end)
  end

  -- Placeholders: styled disabled once, at construction -- apply() never touches them (they carry
  -- no live state; a future task wires real A/P flight modes onto this row).
  for _, id in ipairs(PLACEHOLDER_ORDER) do
    local btn = placeholders[id]
    btn:setBackground(Theme.role("button"))   -- uniform: button colour bg + ORANGE (inert) text
    btn:setForeground(Theme.DISABLED_FG)
    btn:setEnabled(false)
  end

  -- apply(state): update elements from the canonical flat cadence state. Idempotent -- safe to
  -- call repeatedly; only ever SETS element props, never polls peripherals (that discipline lives
  -- in ui/basalt/app.lua's scheduled loops, off this render-gated path).
  --
  -- ui.panels.fcs's buttonStates() reads ctx.positionHold/mode (the SAME field names the
  -- canonical cadence state already uses (ui/basalt/app.lua:M.buildState)), so `state` is passed
  -- straight through with no ctx remapping.
  local function apply(state)
    state = state or {}

    local btnStates = FcsPanel.buttonStates(state)
    for _, id in ipairs(CTRL_ORDER) do
      local style = BUTTON_STYLE[btnStates[id]] or BUTTON_STYLE.disabled
      local btn = buttons[id]
      -- Uniform scheme: button colour bg, ORANGE text when inert (disabled), font colour otherwise.
      -- The state (style.enabled) is still tracked for the next-task state-feedback treatment.
      btn:setBackground(Theme.role("button"))
      btn:setForeground(style.enabled == false and Theme.DISABLED_FG or Theme.role("font"))
      btn:setEnabled(style.enabled)
    end
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      posHoldBtn = buttons.positionHold,
      clrDampBtn = buttons.clearDamped,
      altHoldBtn = placeholders.altHold,
      waypointBtn = placeholders.waypoint,
      rtbBtn = placeholders.rtb,
    },
  }
end

return M
