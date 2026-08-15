-- nav/app.lua
-- NAV role bootstrap. Reuses ui.basalt.app.ensureBasalt to load the vendored Basalt (the nav role
-- ships release/basalt-full.lua, like the ui role), then stands up a terminal frame with a MAIN and
-- a CONFIG tab and runs event-driven scheduled loops: hear GPS -> receiver, relay fix+heading on a
-- timer, render on a quantized gate. The peripheral + event glue is thin; all the logic lives in
-- nav.runtime / nav.ui.* (unit-tested). buildRuntime/routeModem/buildState are injectable seams so
-- the whole pipeline self-tests headless. NO peripheral/Basalt access at module LOAD; run() is
-- IN-GAME ONLY (it calls basalt.run(), which blocks forever).
local navconfig  = require("nav.config")
local NavRuntime = require("nav.runtime")
local Main       = require("nav.ui.main")
local ConfigPage = require("nav.ui.config")

local M = {}
M.CONFIG_PATH = navconfig.PATH

-- Basalt loader (mirrors ui/basalt/app.lua's ensureBasalt -- deliberately NOT required from there,
-- so the nav role's dependency closure stays lean and never pulls in the whole cockpit page
-- registry). loadfile(path,nil,_ENV), never dofile(): CC:Tweaked's dofile loads with the BIOS's
-- bare _G (no require/package), and the vendored bundle needs package.path for its module loader.
-- The nav role ships release/basalt-full.lua (extraFiles), so a candidate path always exists.
M.BASALT_PATHS = { "/basalt-full.lua", "/release/basalt-full.lua" }

function M.ensureBasalt(opts)
  opts = opts or {}
  local paths = opts.paths or M.BASALT_PATHS
  local exists = opts.exists or fs.exists
  local doLoadfile = opts.loadfile or loadfile
  for _, path in ipairs(paths) do
    if exists(path) then
      local chunk, err = doLoadfile(path, nil, _ENV)
      if not chunk then error("Basalt did not parse: " .. tostring(err)) end
      local ok, basalt = pcall(chunk)
      if not ok or type(basalt) ~= "table" then error("Basalt failed to load: " .. tostring(basalt)) end
      return basalt
    end
  end
  error("Basalt not found -- reinstall the nav role via the Suite")
end

-- M.buildRuntime(deps): loads config and wires the nav runtime. deps (all optional/injectable):
--   gpsModem, wiredModem (raw modems), navtable (peripheral), find/wrap (peripheral API overrides),
--   now (clock fn), configPath.
function M.buildRuntime(deps)
  deps = deps or {}
  local wrap = deps.wrap or peripheral.wrap
  local find = deps.find or peripheral.find
  local now  = deps.now  or function() return os.epoch("utc") end
  local cfg  = navconfig.withDefaults(select(1, navconfig.load(deps.configPath or M.CONFIG_PATH)) or {})

  local gpsModem = deps.gpsModem
  local wiredModem = deps.wiredModem
  if not gpsModem then gpsModem = find("modem", function(_, m) return m.isWireless and m.isWireless() end) end
  if not wiredModem then wiredModem = find("modem", function(_, m) return not (m.isWireless and m.isWireless()) end) end
  if gpsModem and gpsModem.open then gpsModem.open(cfg.channel) end

  local navtable = deps.navtable
  if not navtable and cfg.navtable and cfg.navtable.name then
    local ok, p = pcall(wrap, cfg.navtable.name)
    if ok then navtable = p end
  end

  local rt = NavRuntime.new({ config = cfg, navtable = navtable, gpsModem = gpsModem,
                              wiredModem = wiredModem, now = now })
  return { nav = rt, config = cfg, gpsModem = gpsModem, wiredModem = wiredModem, uiRev = 0, now = now,
           save = function(c) navconfig.save(M.CONFIG_PATH, c or cfg) end }
end

-- M.routeModem(runtime, ch, replyCh, msg, dist): feed ONLY GPS-channel messages to the receiver.
function M.routeModem(runtime, ch, replyCh, msg, dist)
  if ch == runtime.config.channel then
    return runtime.nav:onModemMessage(ch, replyCh, msg, dist)
  end
  return false
end

-- M.buildState(runtime, now): the flat state the render gate + pages read.
function M.buildState(runtime, now)
  now = now or runtime.now()
  return { nav = runtime.nav:status(now), uiRev = runtime.uiRev }
end

-- M.signature(state): quantized render-gate key -- repaint only when the fix/heading/mesh changes.
function M.signature(state)
  local s = state.nav or {}
  local f = s.fix
  local pos = f and ("%d,%d,%d"):format(math.floor(f.x + 0.5), math.floor(f.y + 0.5), math.floor(f.z + 0.5)) or "nofix"
  local n = 0
  for _ in pairs(s.beacons or {}) do n = n + 1 end
  return table.concat({ pos, tostring(s.heading and math.floor(s.heading + 0.5) or "-"),
    tostring(n), tostring(f and f.quality or 0), tostring(state.uiRev or 0) }, "|")
end

-- ===== run(): in-game only =====
function M.run(deps)
  deps = deps or {}
  local basalt = M.ensureBasalt(deps.basaltOpts)
  local runtime = M.buildRuntime(deps)

  local root = basalt.getMainFrame()
  local w, h = root:getSize()

  -- Two tab child frames + a top button row.
  local mainFrame = root:addFrame({ x = 1, y = 2, width = w, height = h - 1 })
  local cfgFrame  = root:addFrame({ x = 1, y = 2, width = w, height = h - 1 })
  local mainPage = Main.build(basalt, mainFrame, runtime, nil)
  local cfgPage  = ConfigPage.build(basalt, cfgFrame, runtime, nil)

  local function show(which)
    mainFrame:setVisible(which == "main")
    cfgFrame:setVisible(which == "config")
    runtime.uiRev = runtime.uiRev + 1
  end
  root:addButton({ x = 1, y = 1, width = 8, height = 1, text = "[MAIN]" }):onClick(function() show("main") end)
  root:addButton({ x = 10, y = 1, width = 10, height = 1, text = "[CONFIG]" }):onClick(function() show("config") end)
  show("main")

  -- (a) hear GPS broadcasts.
  basalt.schedule(function()
    while true do
      local _, _, ch, replyCh, msg, dist = os.pullEvent("modem_message")
      M.routeModem(runtime, ch, replyCh, msg, dist)
    end
  end)

  -- (b) relay fix+heading onto the craft wire, event-driven with a sleep between (never busy-wait).
  basalt.schedule(function()
    while true do
      pcall(function() runtime.nav:step(os.epoch("utc")) end)
      sleep((runtime.config.intervalMs or 500) / 1000)
    end
  end)

  -- (c) render gate: repaint only when the quantized signature changes.
  basalt.schedule(function()
    local lastSig = nil
    while true do
      local state = M.buildState(runtime, os.epoch("utc"))
      local sig = M.signature(state)
      if sig ~= lastSig then
        lastSig = sig
        pcall(mainPage.apply, state)
      end
      sleep(0.3)
    end
  end)

  basalt.run()
end

return M
