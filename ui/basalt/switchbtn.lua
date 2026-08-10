-- ui/basalt/switchbtn.lua
-- Color-state switch button: a Basalt button whose colours reflect a small state enum.
-- Reused on the merged flight page for ENG SW / FCS / GND and the MODE placeholders.
-- The pure STYLE map is unit-tested; the Basalt wiring is exercised by a construction probe.
local M = {}

-- Pure state -> style. States:
--   "on"       active/engaged  -> green
--   "off"      inactive        -> red
--   "disabled" inert           -> gray (used for the MODE placeholders and gated controls)
-- Anything unknown falls back to disabled (never throws).
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
  local function set(state)
    local s = M.styleFor(state)
    btn:setBackground(colors[s.bg])
    btn:setForeground(colors[s.fg])
    btn:setEnabled(s.enabled)
    return btn
  end
  set("disabled")   -- construct inert until the first apply() sets a real state
  return { button = btn, set = set }
end

return M
