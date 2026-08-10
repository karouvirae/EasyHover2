-- ui/basalt/pages/nav.lua
-- NAV cockpit page: placeholder navigation/routing interface.
-- This page establishes the nav-aware build signature: M.build(basalt, frame, runtime, nav)
-- with a `nav` parameter (per-monitor navigation stack) that navigating pages (BIT/CONFIG hub,
-- sub-menus, etc.) will use to push/pop screens on the stack.
--
-- Current content: a placeholder body Label + one enabled [BIT/CONFIG] Button that pushes
-- "bitconfig" onto the nav stack. Future expansion: map/route visualization, flight plan UI.
--
-- Follows the Task 15 template EXACTLY (see ui/basalt/pages/emc.lua's header comment for the
-- full Basalt API provenance notes -- not re-derived here): module exports `M.id`, `M.title`,
-- a Basalt-free testable `M._onButton(nav, id, now)` intent seam, and `M.build(basalt,
-- frame, runtime, nav) -> { id, apply(state), elements }` with an idempotent apply() that only
-- reads `state` (the canonical flat cadence state -- ui/basalt/app.lua:M.buildState) and never
-- polls peripherals.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/M._onButton/the
-- apply() closure, so `require("ui.basalt.pages.nav")` loads clean headless.

local M = {}
M.id = "nav"
M.title = "NAV"

-- ===== M._onButton: the TESTABLE intent seam. No Basalt here. =====
--
-- Navigational intent dispatch: button presses that affect the nav stack.
-- If id == "bitconfig", push "bitconfig" onto the nav stack and return the id.
-- All other ids return nil (no effect).
--
-- Guard: nav must be present (a Nav instance from ui/basalt/nav.lua).
function M._onButton(nav, id, now)
  if not nav then return nil end
  if id == "bitconfig" then
    nav:push("bitconfig")
    return "bitconfig"
  end
  return nil
end

-- ===== M.build: construct the element tree =====

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  -- Placeholder body Label: "NAV — map/route coming soon"
  -- autoSize=false requires explicit width; positioned at y=2 to leave room for title.
  local bodyLabel = frame:addLabel({
    x = x,
    y = 2,
    width = iw,
    height = 1,
    text = "NAV - map/route coming soon",
    autoSize = false,
  })

  -- [BIT/CONFIG] button: entry point to the BIT/CONFIG hub (pushed onto nav stack).
  -- Positioned below the body label with some vertical spacing.
  local bitconfigBtn = frame:addButton({
    x = x,
    y = 4,
    width = iw,
    height = 1,
    text = "[BIT/CONFIG]",
  })
  bitconfigBtn:setEnabled(true)

  -- onClick handler for [BIT/CONFIG]: call M._onButton with the nav stack.
  bitconfigBtn:onClick(function()
    M._onButton(nav, "bitconfig", os.epoch("utc"))
  end)

  -- apply(state): update elements from the canonical flat cadence state. Idempotent -- safe to
  -- call repeatedly; only ever SETS element props, never polls peripherals (that discipline lives
  -- in ui/basalt/app.lua's scheduled loops, off this render-gated path).
  --
  -- This placeholder page has no live telemetry values; apply() is a no-op (or trivial
  -- idempotent refresh). Keep the signature/shape consistent with the other pages.
  local function apply(state)
    state = state or {}
    -- No live state updates needed for this placeholder page.
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      bodyLabel = bodyLabel,
      bitconfigBtn = bitconfigBtn,
    },
  }
end

return M
