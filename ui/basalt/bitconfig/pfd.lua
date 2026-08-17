-- ui/basalt/bitconfig/pfd.lua
-- PFD RATE sub-menu (BIT/CONFIG hub, screen id "pfdrate" -- deliberately NOT "pfd", which is the
-- COCKPIT PFD page in ui/basalt/app.lua's M.PAGES; a shared id would make the nav stack open the
-- cockpit page instead of this config screen). A single numeric stepper over the PFD redraw cadence
-- (ui.config's pfd.renderMs), persisted to /eh2_ui_config.tbl like every other UI menu.
--
-- Follows the bitconfig template: M.id/M.title, a PURE testable seam (M.step), an effectful persist
-- seam (M._applyStep), and M.build(basalt, frame, runtime, nav, deps) -> { id, apply, elements }
-- with an idempotent apply(). NO peripheral/Basalt access at module LOAD. ui.basalt.app is required
-- LAZILY inside M._applyStep (the page registry requires this module at its own top; a top-level
-- back-require would loop mid-load -- same rationale as uical.lua's header note).
local Config    = require("ui.config")
local configkit = require("ui.basalt.configkit")

local M = {}
M.id = "pfdrate"
M.title = "PFD RATE"

M.STEP    = 25    -- ms per press
M.MIN     = 50    -- floor (20 Hz): faster costs more shared render budget the FCS also draws from
M.MAX     = 500   -- ceiling (2 Hz)
M.DEFAULT = 100

-- PURE: step cfg.pfd.renderMs by delta*STEP, clamped to [MIN,MAX]; seeds pfd/renderMs if absent.
function M.step(cfg, delta)
  cfg.pfd = cfg.pfd or {}
  local cur = tonumber(cfg.pfd.renderMs) or M.DEFAULT
  local v = cur + (delta or 0) * M.STEP
  if v < M.MIN then v = M.MIN end
  if v > M.MAX then v = M.MAX end
  cfg.pfd.renderMs = v
  return v
end

-- Effectful: step + persist. deps.save defaults to ui.config's M.save at BasaltApp.CONFIG_PATH.
function M._applyStep(runtime, delta, deps)
  local BasaltApp = require("ui.basalt.app")
  deps = deps or {}
  local save = deps.save or Config.save
  local v = M.step(runtime.config, delta)
  save(BasaltApp.CONFIG_PATH, runtime.config)
  return v
end

function M.build(basalt, frame, runtime, nav, deps)
  deps = deps or {}
  local w, h = frame:getSize()
  local x, iw = 2, math.max(1, w - 2)

  local headerLabel = frame:addLabel({ x = x, y = 2, width = iw, height = 1, autoSize = false, text = M.title })
  local valueLabel  = frame:addLabel({ x = x, y = 4, width = iw, height = 1, autoSize = false, text = "" })

  local function refresh()
    local ms = (runtime and runtime.config and runtime.config.pfd and runtime.config.pfd.renderMs) or M.DEFAULT
    valueLabel:setText(configkit.fitLabel(string.format("RENDER %dms  %.1fHz", ms, 1000 / ms), iw))
  end

  local stepRow = configkit.actionRow(frame, { x = x, y = 5, w = iw }, {
    { label = "- SLOWER", onClick = function() M._applyStep(runtime, -1, deps); refresh() end },
    { label = "+ FASTER", onClick = function() M._applyStep(runtime,  1, deps); refresh() end },
  })
  local backRow = configkit.actionRow(frame, { x = x, y = 6, w = iw }, {
    { label = "<", onClick = function() if nav then nav:pop() end end },
  })

  refresh()

  return {
    id = M.id,
    apply = function(_state) refresh() end,
    elements = { headerLabel = headerLabel, valueLabel = valueLabel, stepRow = stepRow, backRow = backRow },
  }
end

return M
