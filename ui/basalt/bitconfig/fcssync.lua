-- ui/basalt/bitconfig/fcssync.lua
-- FCS SYNC sub-menu (BIT/CONFIG hub, screen id "fcssync"): operator control for the gated
-- config-answer server. Allows starting/stopping the server and displays the current link
-- status (whether the FCS boot client is actively talking to us).
--
-- Follows the Task 15/17/21 template (see ui/basalt/bitconfig/tuning.lua's header for the full
-- Basalt API provenance notes): module exports `M.id`, `M.title`, a Basalt-free PURE view-model
-- (M.FRESH_MS / M.linkStatus / M._onButton), and `M.build(basalt, frame, runtime, nav) ->
-- { id, apply(state), elements }`.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/the closures it
-- returns, so `require("ui.basalt.bitconfig.fcssync")` loads clean headless.

local btnfit = require("ui.basalt.btnfit")

local M = {}
M.id = "fcssync"
M.title = "FCS SYNC"

-- Freshness threshold (ms): if lastSeen is older than this, report "WAITING FOR FCS".
M.FRESH_MS = 3000

-- ===== M.linkStatus: PURE, Basalt-free view-model of link health =====

-- Given a status table from runtime.cfgserver:status() and the current time (os.epoch("utc") ms),
-- returns one of:
--   "STOPPED"        - server is not running
--   "FCS ACTIVE"     - server is running AND lastSeen is recent (within FRESH_MS)
--   "WAITING FOR FCS" - server is running BUT lastSeen is stale or nil
function M.linkStatus(status, now)
  if not status.running then
    return "STOPPED"
  end
  if status.lastSeen and (now - status.lastSeen) <= M.FRESH_MS then
    return "FCS ACTIVE"
  end
  return "WAITING FOR FCS"
end

-- ===== M._onButton: PURE, Basalt-free button handler =====

-- Handle start/stop button clicks. Testable; no Basalt/peripheral access.
-- id: button id ("start" or "stop")
-- runtime: object with cfgserver (:start(), :stop()) and uiRev (version counter)
-- now: os.epoch("utc") for potential future use
-- Returns: the id acted on, or nil if no action taken.
function M._onButton(runtime, id, now)
  if id == "start" then
    runtime.cfgserver:start()
    runtime.uiRev = (runtime.uiRev or 0) + 1
    return id
  elseif id == "stop" then
    runtime.cfgserver:stop()
    runtime.uiRev = (runtime.uiRev or 0) + 1
    return id
  end
  return nil
end

-- ===== M.build: construct the FCS SYNC element tree =====

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local headerLabel = frame:addLabel({ x = x, y = 2, width = iw, height = 1, autoSize = false, text = M.title })

  local dataTop = 3
  local serverLbl = frame:addLabel({ x = x, y = dataTop, width = iw, height = 1, autoSize = false, text = "SERVER: --" })
  local linkLbl   = frame:addLabel({ x = x, y = dataTop + 1, width = iw, height = 1, autoSize = false, text = "LINK: --" })

  local footerY = dataTop + 3

  -- Compact, label-sized + centred (was a full-width split / bar).
  local ssGeo = btnfit.grid({ "START", "STOP" }, { x0 = 1, availW = w, y0 = footerY, gap = 1, align = "center" })
  local startBtn = frame:addButton({ x = ssGeo[1].x, y = footerY, width = ssGeo[1].w, height = 1, text = "START" })
  local stopBtn  = frame:addButton({ x = ssGeo[2].x, y = footerY, width = ssGeo[2].w, height = 1, text = "STOP" })

  local ssBackGeo = btnfit.grid({ "< BACK" }, { x0 = 1, availW = w, y0 = footerY + 1, gap = 1, align = "center" })
  local backBtn = frame:addButton({ x = ssBackGeo[1].x, y = footerY + 1, width = ssBackGeo[1].w, height = 1, text = "< BACK" })

  startBtn:onClick(function()
    M._onButton(runtime, "start", os.epoch("utc"))
  end)

  stopBtn:onClick(function()
    M._onButton(runtime, "stop", os.epoch("utc"))
  end)

  backBtn:onClick(function()
    if nav then nav:pop() end
  end)

  -- apply(state): read runtime.cfgserver:status() live (a cheap table read, NOT a peripheral
  -- poll -- safe on the render path), set the SERVER + LINK Labels via M.linkStatus, and
  -- reflect START disabled when running / STOP disabled when stopped. Idempotent.
  -- NOTE: server status isn't in the cadence signature, so live-freshness updates ride the
  -- frequent telemetry-driven repaints -- acceptable; a dedicated refresh could be added at
  -- assembly if wanted.
  local function apply(_state)
    local status = runtime.cfgserver:status()
    local now = os.epoch("utc")

    -- Update SERVER label: running state
    local serverText = status.running and "RUNNING" or "STOPPED"
    serverLbl:setText("SERVER: " .. serverText)

    -- Update LINK label: freshness
    local linkText = M.linkStatus(status, now)
    linkLbl:setText("LINK: " .. linkText)

    -- Disable START when running, STOP when stopped
    startBtn:setEnabled(not status.running)
    stopBtn:setEnabled(status.running)
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      headerLabel = headerLabel,
      serverLbl = serverLbl,
      linkLbl = linkLbl,
      startBtn = startBtn,
      stopBtn = stopBtn,
      backBtn = backBtn,
    },
  }
end

return M
