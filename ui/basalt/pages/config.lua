-- ui/basalt/pages/config.lua
-- CONFIG cockpit page: Basalt port of the monitor-assignment + read-only device-summary slice of
-- ui/panels/config.lua, hosted on the TERMINAL frame (the PC terminal, not a monitor -- config is
-- never a monitor-displayable page, so it is deliberately absent from M.ASSIGN_CYCLE below).
--
-- SCOPE (per task-17-brief.md): monitor assignment cycle + a read-only device summary ONLY. The
-- fuller UI config editing that ui/panels/config.lua's action() also supports -- device binding
-- (relay/pump/tank), relay-side cycling, engine timing tuning (pulse/interval/invert/kickstart),
-- and fuel calibration -- is DEFERRED to the "UI CAL" hub sub-menu (Phase 6). This page does NOT
-- build bindRelay/bindPump/bindTank/relaySide/scan/calFuel/pulseUp/pulseDn/intervalUp/intervalDn/
-- toggleInvert/toggleKick controls; it only reads config.relay/config.fuel/config.engine to RENDER
-- a status summary via the reused labelFor/timingLine/fmtInterval helpers.
--
-- Follows the Task 15/16 template EXACTLY (see ui/basalt/pages/emc.lua's header comment for the
-- full Basalt API provenance notes -- not re-derived here): module exports `M.id`, `M.title`, a
-- Basalt-free testable `M._onButton(runtime, id, now, saveFn)` intent seam, and
-- `M.build(basalt, frame, runtime) -> { id, apply(state), elements }` with an idempotent apply()
-- that only reads runtime.config (config edits bump uiRev, which forces a repaint through the
-- render-gate, so this stays fresh -- same discipline emc.lua's relayBound() documents) and never
-- polls peripherals.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/M._onButton/the
-- apply() closure, so `require("ui.basalt.pages.config")` loads clean headless.
local ConfigPanel = require("ui.panels.config")
local Config       = require("ui.config")
local Picker       = require("ui.basalt.picker")   -- pure module (no ui.basalt.app dep) -> safe at top
-- NOTE: ui.basalt.app is required LAZILY below (inside M._onButton / M.build), NOT at module
-- top. ui/basalt/app.lua's page registry (M.PAGES, Task 27) requires this module at ITS OWN
-- module top -- a top-level require("ui.basalt.app") here would close the loop mid-load
-- (require("ui.basalt.app") -> require(this file) -> require("ui.basalt.app") again, still
-- executing) and CraftOS-PC's require rejects that with "loop or previous error loading module"
-- (verified empirically). A lazy require inside the functions below is safe: by the time
-- M._onButton/M.build actually RUN (never at require-time), ui.basalt.app has always already
-- finished loading and is served straight from require's cache.

local M = {}
M.id = "config"
M.title = "CONFIG"

-- The monitor-displayable pages this cockpit currently ships. "config" is intentionally absent --
-- it's the terminal frame's own content, never assignable to a monitor. NOTE: the final
-- assignable-page set is confirmed in the assembly task (T27); this is the working default (nav
-- and ap are reserved ids -- their pages land in Tasks 18/19).
M.ASSIGN_CYCLE = { "emc", "fcs", "flight", "nav", "ap", "pfd" }

-- M.nextAssign(cur) -> nextPageId|nil
-- Mirrors ui/main.lua's nextAssign (lines 222-231) exactly: nil -> first entry; the last entry ->
-- nil (unassigned, wrapping past the end); an unrecognised current value falls back to the first
-- entry (same as ui/main.lua's trailing `return ASSIGN_CYCLE[1]`).
function M.nextAssign(cur)
  if cur == nil then return M.ASSIGN_CYCLE[1] end
  for i, v in ipairs(M.ASSIGN_CYCLE) do
    if v == cur then
      if i == #M.ASSIGN_CYCLE then return nil end
      return M.ASSIGN_CYCLE[i + 1]
    end
  end
  return M.ASSIGN_CYCLE[1]
end

-- ===== M._onButton: the TESTABLE intent seam. No Basalt here. =====
--
-- Only handles "assign:<name>" ids (the only interactive control this page builds). Computes the
-- next assignment, mutates runtime.config.assign IN PLACE (same as ui/main.lua's applyConfigOp's
-- cycleAssign branch), persists via saveFn (default Config.save, injectable for tests), and bumps
-- runtime.uiRev so the render-gate repaints the summary/labels (mirrors ui/main.lua's markDirty()
-- convention -- see ui/basalt/app.lua's M.buildState, which reads runtime.uiRev straight through).
-- Live frame re-resolution (actually moving a page onto the newly-assigned monitor) is an ASSEMBLY
-- concern (T27) -- this seam only updates config + uiRev.
function M._onButton(runtime, id, now, saveFn)
  local BasaltApp = require("ui.basalt.app")
  saveFn = saveFn or Config.save
  if type(id) ~= "string" or id:sub(1, 7) ~= "assign:" then return nil end
  local monitor = id:sub(8)

  local next = M.nextAssign(runtime.config.assign[monitor])
  runtime.config.assign[monitor] = next
  saveFn(BasaltApp.CONFIG_PATH, runtime.config)
  runtime.uiRev = (runtime.uiRev or 0) + 1

  return { kind = "config", op = "cycleAssign", monitor = monitor, assigned = next }
end

-- Options for a monitor's assignment dropdown: "(none)" (unassigned) + each monitor-displayable page.
function M._assignOptions()
  local opts = { { text = "(none)", value = false } }
  for _, id in ipairs(M.ASSIGN_CYCLE) do opts[#opts + 1] = { text = id, value = id } end
  return opts
end

-- Set (not cycle) a monitor's page assignment directly from the dropdown. `pageId` false/nil ->
-- unassigned. Persists + bumps uiRev, same as the old cycle seam. Testable (saveFn injectable).
function M._pickAssign(runtime, monitor, pageId, saveFn)
  local BasaltApp = require("ui.basalt.app")
  saveFn = saveFn or Config.save
  runtime.config.assign[monitor] = pageId or nil
  saveFn(BasaltApp.CONFIG_PATH, runtime.config)
  runtime.uiRev = (runtime.uiRev or 0) + 1
  return { kind = "config", op = "assign", monitor = monitor, assigned = pageId or nil }
end

-- ===== M.build: construct the element tree =====

function M.build(basalt, frame, runtime)
  local BasaltApp = require("ui.basalt.app")
  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local monitors = runtime.monitors or BasaltApp.discoverMonitors()

  local y = 2
  local monHeader = frame:addLabel({ x = x, y = y, width = iw, height = 1, autoSize = false, text = "MONITORS" })
  y = y + 1

  -- Per-monitor assignment DROPDOWN (name label on the left, page picker on the right) -- replaces
  -- the old click-to-cycle button so you pick a page from a list instead of cycling.
  local assignOpts = M._assignOptions()
  local monPickers = {}
  for _, name in ipairs(monitors) do
    local nameW = math.min(#name + 1, math.max(4, math.floor(iw / 2)))
    -- Assignment dropdown sized to the page names it shows (emc/fcs/nav/flight/(none) <= ~6 chars),
    -- not spanning the whole shell width.
    local assignW = math.min(math.max(4, iw - nameW - 1), 10)
    frame:addLabel({ x = x, y = y, width = nameW, height = 1, autoSize = false, text = name })
    monPickers[name] = Picker.make(frame, {
      x = x + nameW + 1, y = y, width = assignW,
      options = assignOpts, current = runtime.config.assign[name] or false, placeholder = "(none)",
      onPick = function(value) M._pickAssign(runtime, name, value) end,
    })
    y = y + 1
  end

  y = y + 1
  local devHeader = frame:addLabel({ x = x, y = y, width = iw, height = 1, autoSize = false, text = "DEVICES" })
  y = y + 1

  local relayLabel  = frame:addLabel({ x = x, y = y,     width = iw, height = 1, autoSize = false, text = "RELAY --" })
  local pumpLabel   = frame:addLabel({ x = x, y = y + 1, width = iw, height = 1, autoSize = false, text = "PUMP --" })
  local tankLabel   = frame:addLabel({ x = x, y = y + 2, width = iw, height = 1, autoSize = false, text = "TANK --" })
  local timingLabel = frame:addLabel({ x = x, y = y + 3, width = iw, height = 1, autoSize = false, text = "TIMING --" })

  -- apply(state): refresh the monitor assignment pickers (current runtime.config.assign) and the
  -- device-summary Labels (from runtime.config) -- reuses ui/panels/config.lua's labelFor/
  -- timingLine helpers so the summary text matches the old terminal-rendered panel exactly.
  -- Idempotent -- safe to call repeatedly; only ever SETS element props, config-derived values
  -- change on uiRev, which the render-gate already keys on (no peripheral polling here).
  local function apply(state)
    state = state or {}
    local cfg = runtime.config
    local assign = cfg.assign or {}

    for _, name in ipairs(monitors) do
      monPickers[name].setOptions(assignOpts, assign[name] or false)
    end

    -- ConfigPanel.labelFor already prefixes these ("RELAY: <name>", "PUMP: <name>", "TANK: <name>")
    -- -- reused verbatim, no re-wrapping, so this summary text matches the old terminal panel.
    relayLabel:setText(ConfigPanel.labelFor({ id = "bindRelay" }, cfg, assign))
    pumpLabel:setText(ConfigPanel.labelFor({ id = "bindPump" }, cfg, assign))
    tankLabel:setText(ConfigPanel.labelFor({ id = "bindTank" }, cfg, assign))
    timingLabel:setText(ConfigPanel.timingLine(cfg, iw))
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      monHeader = monHeader, devHeader = devHeader,
      monPickers = monPickers,
      relayLabel = relayLabel, pumpLabel = pumpLabel, tankLabel = tankLabel, timingLabel = timingLabel,
    },
  }
end

return M
