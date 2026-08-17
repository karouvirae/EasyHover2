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
  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)
  local y = 2

  -- Build one button per menu item (left-aligned, column layout)
  local elements = {}
  for _, item in ipairs(M.ITEMS) do
    local btn = frame:addButton({
      x = x,
      y = y,
      width = iw,
      height = 1,
      text = item.label,
    })
    btn:setEnabled(true)
    -- Capture item.id in a closure to preserve it for the onClick handler
    local itemId = item.id
    btn:onClick(function()
      M._onButton(nav, itemId, os.epoch("utc"))
    end)
    elements[itemId] = btn
    y = y + 1
  end

  -- Back button: positioned after all menu items
  local backBtn = frame:addButton({
    x = x,
    y = y,
    width = iw,
    height = 1,
    text = "< BACK",
  })
  backBtn:setEnabled(true)
  backBtn:onClick(function()
    M._onButton(nav, "back", os.epoch("utc"))
  end)
  elements.backBtn = backBtn

  -- apply(state): update elements from the canonical flat cadence state. Idempotent -- safe to
  -- call repeatedly; only ever SETS element props, never polls peripherals (that discipline lives
  -- in ui/basalt/app.lua's scheduled loops, off this render-gated path).
  --
  -- This menu page has no live telemetry values; apply() is a no-op (or trivial
  -- idempotent refresh). Keep the signature/shape consistent with the other pages.
  local function apply(state)
    state = state or {}
    -- No live state updates needed for this menu page.
  end

  return {
    id = M.id,
    apply = apply,
    elements = elements,
  }
end

return M
