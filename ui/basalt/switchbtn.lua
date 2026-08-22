-- ui/basalt/switchbtn.lua
-- Color-state switch button: a Basalt button whose colours reflect a small state enum.
-- Reused on the merged flight page for ENG SW / FCS / GND and the MODE placeholders.
-- The pure STYLE map is unit-tested; the Basalt wiring is exercised by a construction probe.
local Theme = require("ui.theme")
local M = {}

-- Pure state -> style. States:
--   "on"       active/engaged
--   "off"      inactive
--   "disabled" inert (MODE placeholders, gated controls) -- not clickable
-- Anything unknown falls back to disabled (never throws).
--
-- The bg/fg here are RETAINED as data for the state enum + the upcoming (next-task) state-feedback
-- feature, but are NO LONGER painted: every switch button now renders in the THEME's button colour +
-- font colour for a uniform look (ui/theme.lua). Only `enabled` still has a live effect. See make().
local STYLE = {
  on       = { bg = "green", fg = "white",     enabled = true },
  off      = { bg = "red",   fg = "white",     enabled = true },
  disabled = { bg = "gray",  fg = "lightGray", enabled = false },
}

function M.styleFor(state)
  return STYLE[state] or STYLE.disabled
end

-- Create a switch button on `frame`. opts = { x, y, width, height=1, text="" }.
-- Returns { button = <basalt button>, set = function(state) -> button }.
-- The caller wires :onClick on the returned button (behaviour differs per use site).
function M.make(frame, opts)
  local btn = frame:addButton({
    x = opts.x, y = opts.y, width = opts.width, height = opts.height or 1,
    text = opts.text or "",
  })
  local ctrl = { button = btn, state = "disabled" }
  function ctrl.set(state)
    ctrl.state = state or "disabled"
    local s = M.styleFor(ctrl.state)
    -- Uniform look: every switch button is the current BUTTON colour. Enabled buttons use the FONT
    -- colour; inert (disabled) buttons use ORANGE text so they read as inert. Painted from the live
    -- scheme (Theme.role) rather than left to Basalt's built-in disabled look. `enabled` stays live;
    -- ctrl.state is tracked for the next-task state-feedback feature (the red/green STYLE map is kept).
    btn:setBackground(Theme.role("button"))
    btn:setForeground(ctrl.state == "disabled" and Theme.DISABLED_FG or Theme.role("font"))
    btn:setEnabled(s.enabled)
    return btn
  end
  ctrl.set("disabled")   -- construct inert until the first apply() sets a real state
  return ctrl
end

return M
