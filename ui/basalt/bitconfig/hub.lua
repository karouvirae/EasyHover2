-- ui/basalt/bitconfig/hub.lua
-- BIT/CONFIG hub menu screen: entry point to six sub-menus (FCS TUNING, MDB-CONF, UI CAL,
-- SENS CAL, DTC, FCS SYNC). Reached from the NAV page's [BIT/CONFIG] button, which pushes
-- "bitconfig" onto the per-monitor nav stack. This hub offers six menu buttons and a Back button.
--
-- Follows the Task 15 template EXACTLY (see ui/basalt/pages/emc.lua's header comment for the
-- full Basalt API provenance notes): module exports `M.id`, `M.title`, `M.ITEMS` (canonical
-- menu definition pinning screen ids for Tasks 21-26), a Basalt-free testable `M._onButton(nav, id, now)`
-- intent seam, and `M.build(basalt, frame, runtime, nav) -> { id, apply(state), elements }`
-- with an idempotent apply() that only reads `state` and never polls peripherals.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/M._onButton/the
-- apply() closure, so `require("ui.basalt.bitconfig.hub")` loads clean headless.

local configkit = require("ui.basalt.configkit")

local M = {}
M.id = "bitconfig"
M.title = "BIT/CONFIG"

-- ===== M.ITEMS: canonical ordered menu definition =====
-- PIN these screen ids; Tasks 21-26 register matching sub-menu ids.
M.ITEMS = {
  { id = "tuning",  label = "FCS TUNING" },
  { id = "mdb",     label = "MDB-CONF" },
  { id = "uical",   label = "UI CAL" },
  { id = "senscal", label = "SENS CAL" },
  { id = "senssource", label = "SENS SOURCE" },
  { id = "pfdrate", label = "PFD RATE" },
  { id = "dtc",     label = "DTC" },
  { id = "fcssync", label = "FCS SYNC" },
}

-- ===== M._onButton: the TESTABLE intent seam. No Basalt here. =====
--
-- Navigational intent dispatch: button presses that affect the nav stack.
-- If id == "back", pop from the nav stack and return "back".
-- If id matches one of M.ITEMS[*].id, push that id onto the nav stack and return it.
-- All other ids return nil (no effect).
--
-- Guard: nav must be present (a Nav instance from ui/basalt/nav.lua).
function M._onButton(nav, id, now)
  if not nav then return nil end
  if id == "back" then
    nav:pop()
    return "back"
  end
  -- Check if id matches one of the menu items
  for _, item in ipairs(M.ITEMS) do
    if item.id == id then
      nav:push(id)
      return id
    end
  end
  return nil
end

-- ===== M.build: construct the element tree =====

function M.build(basalt, frame, runtime, nav)
  -- A centred menu column whose buttons are all sized to the widest label ("SENS SOURCE"), so the
  -- hub is a compact uniform stack rather than full-width bars. One item per M.ITEMS + a "< BACK".
  local items = {}
  for _, item in ipairs(M.ITEMS) do
    local itemId = item.id
    items[#items + 1] = { id = itemId, label = item.label,
      onClick = function() M._onButton(nav, itemId, os.epoch("utc")) end }
  end
  items[#items + 1] = { id = "back", label = "< BACK",
    onClick = function() M._onButton(nav, "back", os.epoch("utc")) end }

  local w = ({ frame:getSize() })[1]
  configkit.titleRow(frame, w, M.title)                 -- ||BIT/CONFIG|| on the top row
  -- Two buttons per row (gap at row 2) so the 8 items aren't squeezed between title + back.
  local menu = configkit.menuColumn(frame, { y = 3, cols = 2, items = items })

  -- Expose the raw Basalt buttons under the item id (backBtn for the back row), matching the old
  -- element shape the tests + callers use.
  local elements = {}
  for id, sw in pairs(menu.buttons) do
    elements[id == "back" and "backBtn" or id] = sw.button
  end

  -- This menu has no live telemetry; apply() is a no-op. Signature kept consistent with other pages.
  local function apply(state) end

  return { id = M.id, apply = apply, elements = elements }
end

return M
