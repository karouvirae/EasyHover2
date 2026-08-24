-- ui/basalt/bitconfig/pfd.lua
-- PFD RATE sub-menu (BIT/CONFIG hub, screen id "pfdrate" -- NOT "pfd", the cockpit page). Sets the
-- PFD cockpit-page redraw rate. The render loop reads ui.config's pfd.renderMs (a sleep interval in
-- ms), but the MENU is expressed in Hz -- the intuitive unit -- so FASTER means MORE renders per
-- second (higher Hz, fewer ms), not fewer. Persisted to /eh2_ui_config.tbl like the other UI menus.
--
-- PURE testable seams (M.step / M.hz / M.msOf) + an effectful persist seam (M._applyStep). NO
-- peripheral/Basalt access at module LOAD. ui.basalt.app is required LAZILY inside M._applyStep.
local Config    = require("ui.config")
local configkit = require("ui.basalt.configkit")

local M = {}
M.id = "pfdrate"
M.title = "PFD RATE"

M.HZ_MIN    = 2     -- 500 ms
M.HZ_MAX    = 20    -- 50 ms  -- faster costs more shared render budget the FCS also draws from
M.HZ_STEP   = 1     -- Hz per press
M.DEFAULT_MS = 100  -- 10 Hz

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

--- msOf(hz) -> the render interval in ms for `hz` renders/second.
function M.msOf(hz) return math.floor(1000 / hz + 0.5) end
--- hz(cfg) -> the current PFD render rate in Hz (from cfg.pfd.renderMs).
function M.hz(cfg)
  local ms = (cfg.pfd and cfg.pfd.renderMs) or M.DEFAULT_MS
  return math.floor(1000 / ms + 0.5)
end

--- PURE: step the render rate by `delta` Hz (positive = FASTER = higher Hz = LOWER renderMs),
--- clamped to [HZ_MIN, HZ_MAX]; stores the resulting renderMs. Seeds pfd/renderMs if absent.
function M.step(cfg, delta)
  cfg.pfd = cfg.pfd or {}
  if type(cfg.pfd.renderMs) ~= "number" then cfg.pfd.renderMs = M.DEFAULT_MS end
  local hz = clamp(M.hz(cfg) + (delta or 0) * M.HZ_STEP, M.HZ_MIN, M.HZ_MAX)
  cfg.pfd.renderMs = M.msOf(hz)
  return cfg.pfd.renderMs
end

--- Effectful: step + persist. deps.save defaults to ui.config's M.save at BasaltApp.CONFIG_PATH.
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

  local headerLabel = configkit.titleRow(frame, ({ frame:getSize() })[1], M.title)
  local valueLabel  = frame:addLabel({ x = x, y = 3, width = iw, height = 1, autoSize = false, text = "" })

  local function refresh()
    local cfg = (runtime and runtime.config) or {}
    local ms = (cfg.pfd and cfg.pfd.renderMs) or M.DEFAULT_MS
    local t = string.format("<RATE %dHz> <%dms>", M.hz(cfg), ms)   -- rate + interval, each in <> brackets
    valueLabel:setWidth(#t)                                          -- centre by positioning (leading
    valueLabel:setPosition(math.max(1, math.floor((w - #t) / 2) + 1), 3)   -- spaces get trimmed)
    valueLabel:setText(t)
  end

  -- SLOWER = -1 Hz (more ms), FASTER = +1 Hz (fewer ms) -- higher Hz = more renders/second. One row
  -- below the status (gap at y=4).
  local stepRow = configkit.actionRow(frame, { x = x, y = 5, w = iw, gap = 1 }, {
    { label = "- SLOWER", onClick = function() M._applyStep(runtime, -1, deps); refresh() end },
    { label = "+ FASTER", onClick = function() M._applyStep(runtime,  1, deps); refresh() end },
  })
  local backRow = configkit.actionRow(frame, { x = x, y = 6, w = iw }, {
    { id = "back", label = "<", onClick = function() if nav then nav:pop() end end },
  })

  refresh()

  return {
    id = M.id,
    apply = function(_state) refresh() end,
    elements = { headerLabel = headerLabel, valueLabel = valueLabel, stepRow = stepRow, backRow = backRow },
  }
end

return M
