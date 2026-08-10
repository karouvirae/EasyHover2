-- ui/basalt/app.lua
-- Cockpit bootstrap: ensure Basalt is loaded, discover monitors, and build one Basalt frame
-- per monitor (honoring mirroring) plus one for the terminal. Pages/panels are a LATER task --
-- this module only stands up the frames + render-loop foundation.
--
-- Basalt load pattern mirrors easyhover2_suitex.lua:602-636 EXACTLY: loadfile(path, nil, _ENV),
-- never dofile() -- CC:Tweaked's dofile (bios.lua) loads with the BIOS's own bare _G, which has
-- no require/package/shell, and the vendored bundle needs package.path for its internal module
-- loader. loadfile(path, nil, _ENV) loads it with THIS program's own environment instead.
--
-- Basalt 2.0 API verified against release/basalt-full.lua (the pinned, vendored FULL build --
-- NOT the unminified upstream source, and NOT from memory):
--   * basalt.createFrame() -- release/basalt-full.lua:367-369. Takes NO monitor argument in this
--     build; the new frame's "term" property defaults to term.current() (elements/BaseFrame.lua,
--     bundled at release/basalt-full.lua:4706-4708: `self.set("term",term.current())`).
--   * frame:setTerm(mon) -- an AUTO-GENERATED accessor, not a hand-written method. BaseFrame.lua
--     defines a "term" property via defineProperty(da,"term",{...}) (release/basalt-full.lua:
--     4698-4704); propertySystem.lua's defineProperty (release/basalt-full.lua:191-208) builds
--     `cb["set"..Name]` / `cb["get"..Name]` for every defined property, so "term" yields
--     setTerm/getTerm with no separate definition anywhere -- confirmed by :getTerm() call sites
--     at lines 3278/3284/3329/3951. The term setter rebinds the frame's renderer to the new
--     term-like table and re-reads width/height from `bb.getSize()`, but ONLY if
--     `bb.setCursorPos` is non-nil (release/basalt-full.lua:4701) -- a mock MUST implement
--     setCursorPos or setTerm silently no-ops.
--   * basalt.getMainFrame() -- release/basalt-full.lua:371-372. Returns (creating if absent) the
--     frame bound to the actual `term.current()` -- this is "the terminal frame".
--   * basalt.update(...) -- release/basalt-full.lua:407-411 (`function b_a.update(...)`).
--     Dispatches the event args through the same handler basalt.run()'s loop uses, then renders
--     every currently-active frame (`for _,f in pairs(_aa) do f:render() f:postRender() end`).
--     The render-interval throttle variable (`aaa`, declared `local aaa=0` near line 355) is 0
--     and is never reassigned anywhere in the bundle, so basalt.update(...) renders
--     unconditionally on every call -- no hidden min-interval to trip a headless probe.
--     NEVER basalt.run(): that blocks on os.pullEventRaw() in a while loop (lines 412-417).
--
-- NO peripheral/Basalt/fs work happens at module LOAD time -- everything is inside M.* functions
-- so `require("ui.basalt.app")` loads clean headless.
local Monitors = require("ui.monitors")
local fnv1a = require("tools.fnv1a")

local Config    = require("ui.config")
local Engine    = require("ui.engine")
local Fuel      = require("ui.fuel")
local CfgServer = require("ui.cfgserver")
local cadence   = require("ui.basalt.cadence")

local modemlib  = require("fcs.comms.modem")
local telemetry = require("fcs.comms.telemetry")
local command   = require("fcs.comms.command")
local health    = require("fcs.comms.health")

local M = {}

-- Same channel convention as ui/main.lua (101-104) and fcs/boot/loaderui.lua's cfgsync client
-- (105-106, mirrored here: the UI is the RESPONDER -- listens on req, sends on reply).
M.CH = { telemetry = 101, command = 102, ack = 103, health = 104 }
M.CFG_CH = { req = 105, reply = 106 }

M.CONFIG_PATH = "/eh2_ui_config.tbl"

-- Installed location first (SuiteX writes /basalt-full.lua there), repo/headless location
-- second (the ui role ships release/basalt-full.lua -- see DECISION note on M.ensureBasalt).
M.BASALT_PATHS = { "/basalt-full.lua", "/release/basalt-full.lua" }

-- Same constant as BOOT_BASE in easyhover2_suitex.lua:155. Duplicated (not required) here on
-- purpose: this module must load with zero side effects, and requiring the Suite engine would
-- pull in its own bootstrap chain just to read one URL string.
local REPO = "https://raw.githubusercontent.com/maar-10/EasyHover2/main"

-- ===== Basalt load (see header comment for the verified API) =====

local function loadBasaltFrom(path, doLoadfile)
  local chunk, err = doLoadfile(path, nil, _ENV)
  if not chunk then
    error("Basalt did not parse: " .. tostring(err))
  end
  local ok, basalt = pcall(chunk)
  if not ok or type(basalt) ~= "table" then
    error("Basalt failed to load: " .. tostring(basalt))
  end
  return basalt
end

local function readManifest()
  if not fs.exists("/manifest.lua") or fs.isDir("/manifest.lua") then return nil end
  local f = fs.open("/manifest.lua", "r")
  if not f then return nil end
  local body = f.readAll()
  f.close()
  local ok, manifest = pcall(textutils.unserialise, body)
  if ok and type(manifest) == "table" then return manifest end
  return nil
end

-- Minimal in-game HTTP fetch fallback -- ONLY reached when neither BASALT_PATHS candidate exists
-- on disk. In practice this should never run: the DECISION (see task-13-report.md) is to ship
-- release/basalt-full.lua IN the `ui` role so Basalt is always present locally, no fetch needed.
-- The actual tools/gen_manifest.lua ROLES change that adds it to the ui role's closure is
-- DEFERRED to Task 27 (assembly), when the ui launcher switches over to this Basalt cockpit --
-- doing it here would need its own manifest-generator tests and risks destabilising the
-- IN SYNC gate this task doesn't own.
local function fetchBasalt()
  if not http then
    error("Basalt not found -- reinstall the ui role via the Suite")
  end
  local url = REPO .. "/release/basalt-full.lua"
  local ok, handle = pcall(http.get, url, { ["Cache-Control"] = "no-cache" })
  if not ok or not handle then
    error("Basalt not found -- reinstall the ui role via the Suite")
  end
  local body = handle.readAll()
  handle.close()
  if not body or body == "" then
    error("Basalt not found -- reinstall the ui role via the Suite")
  end
  local manifest = readManifest()
  if manifest and manifest.basalt then
    if #body ~= manifest.basalt.size or fnv1a(body) ~= manifest.basalt.sum then
      error("Basalt fetch arrived corrupt; nothing was changed.")
    end
  end
  local f = fs.open("/basalt-full.lua", "w")
  if not f then
    error("could not write /basalt-full.lua (disk full?)")
  end
  f.write(body)
  f.close()
  return loadBasaltFrom("/basalt-full.lua", loadfile)
end

-- M.ensureBasalt(opts) -> basalt module table (the loaded Basalt 2.0 library).
-- opts.paths    -- override M.BASALT_PATHS (injectable for tests)
-- opts.exists   -- override fs.exists       (injectable for tests)
-- opts.loadfile -- override loadfile        (injectable for tests)
function M.ensureBasalt(opts)
  opts = opts or {}
  local paths = opts.paths or M.BASALT_PATHS
  local exists = opts.exists or fs.exists
  local doLoadfile = opts.loadfile or loadfile
  for _, path in ipairs(paths) do
    if exists(path) then
      return loadBasaltFrom(path, doLoadfile)
    end
  end
  return fetchBasalt()
end

-- ===== Monitor discovery =====

-- M.discoverMonitors(getNames, getType) -> { <monitor peripheral name>, ... }
-- Injectable for tests; defaults to the real peripheral API.
function M.discoverMonitors(getNames, getType)
  getNames = getNames or peripheral.getNames
  getType = getType or peripheral.getType
  local names = {}
  for _, name in ipairs(getNames()) do
    if getType(name) == "monitor" then
      names[#names + 1] = name
    end
  end
  return names
end

-- ===== Frame construction =====

-- M.buildFrames(basalt, assign, present, wrap) -> {
--   terminal = <frame>,                                     -- bound to the real terminal
--   monitors = { [monitorName] = { frame = <frame>, panelId = <panelId> }, ... },
--   resolved = Monitors.resolve(assign, present),
-- }
-- One Basalt frame PER assigned monitor name: mirrored monitors (several names -> the same
-- panelId) each still get their own frame, since each is a distinct physical term that must be
-- rendered to independently, even though they'll later show the same panel content.
function M.buildFrames(basalt, assign, present, wrap)
  wrap = wrap or peripheral.wrap
  local resolved = Monitors.resolve(assign, present)
  local monitors = {}
  for name, panelId in pairs(resolved.assigned) do
    local mon = wrap(name)
    local frame = basalt.createFrame()
    frame:setTerm(mon)
    monitors[name] = { frame = frame, panelId = panelId }
  end
  local terminal = basalt.getMainFrame()
  return { terminal = terminal, monitors = monitors, resolved = resolved }
end

-- ===== Runtime: comms/engine/fuel machinery (reused verbatim from ui/main.lua) =====

-- Real atomic-tmp-write-free file reader for cfgserver -- mirrors fcs/boot/loaderui.lua's
-- realRead exactly (read-only: cfgserver only ever answers `req` frames with file bodies).
local function realRead(path)
  if fs.exists(path) and not fs.isDir(path) then
    local f = fs.open(path, "r")
    local b = f.readAll()
    f.close()
    return b
  end
  return nil
end

-- M.buildRuntime(deps) -> runtime
-- deps.modem   -- a modem peripheral (default peripheral.find("modem"))
-- deps.wrap    -- peripheral.wrap override (default peripheral.wrap)
-- deps.find    -- peripheral.find override, used only when deps.modem is absent
-- deps.read    -- file reader for cfgserver, (path) -> body|nil (default realRead)
--
-- NO peripheral access happens outside this function -- `require("ui.basalt.app")` stays clean
-- headless; a test supplies deps.modem/deps.wrap/deps.read so this runs under CraftOS-PC too.
function M.buildRuntime(deps)
  deps = deps or {}
  local wrap = deps.wrap or peripheral.wrap
  local find = deps.find or peripheral.find
  local read = deps.read or realRead

  local modem = deps.modem or find("modem")
  assert(modem, "UI-PC needs a modem on the wired network")

  local CH, CFG_CH = M.CH, M.CFG_CH

  -- One link per logical channel (UI listens on telemetry/ack/health, sends on command) --
  -- PLUS the cfgsync link, mirrored the opposite way round from fcs/boot/loaderui.lua's client:
  -- the UI listens on req (105) and sends replies on reply (106).
  local telLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.telemetry })
  local ackLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.ack })
  local hbLink  = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.health })
  local cfgLink = modemlib.wrap(modem, { txCh = CFG_CH.reply, rxCh = CFG_CH.req })
  for _, c in pairs(CH) do modem.open(c) end
  for _, c in pairs(CFG_CH) do modem.open(c) end

  local rx = telemetry.Rx.new()
  local sender = command.Sender.new({ timeout = 0.5 })
  local hbRx = health.Rx.new({ timeout = 2.0 })

  local config = Config.withDefaults(select(1, Config.load(M.CONFIG_PATH)) or {})

  -- Engine relay: dumb passthrough writer -- ui/engine.lua owns ALL inversion (see ui/main.lua's
  -- header comment on the same construction; ported verbatim, just using the injected `wrap`).
  local relay = nil
  local function rebindRelay()
    relay = nil
    if config.relay.name and config.relay.side then
      local ok, p = pcall(wrap, config.relay.name)
      if ok then relay = p end
    end
  end
  rebindRelay()

  local function writer(signal)
    if not relay then return false end
    local ok = pcall(relay.setOutput, config.relay.side, signal)
    return ok
  end

  local engine = Engine.new(config.engine, writer)

  -- Fuel readers (sink over config.fuel.<role>; pure fraction math lives in ui/fuel.lua).
  local function makeFuelReader(role)
    return function()
      local fc = config.fuel[role]
      if not fc or not fc.name then return 0, nil end
      local ok, p = pcall(wrap, fc.name)
      if not ok or not p then return 0, nil end
      if fc.kind == "fluid" then
        if p.getFuelAmountMb then
          local ok1, amt = pcall(p.getFuelAmountMb)
          local cap = nil
          if p.getFuelCapacityMb then
            local ok2, c = pcall(p.getFuelCapacityMb)
            if ok2 then cap = c end
          end
          return (ok1 and amt) or 0, cap
        elseif p.tanks then
          local ok3, tanks = pcall(p.tanks)
          local t = ok3 and tanks and tanks[1]
          if t then return t.amount or 0, t.capacity end
          return 0, nil
        end
        return 0, nil
      else
        local amount = 0
        if p.list then
          local ok4, items = pcall(p.list)
          if ok4 and items then
            for _, item in pairs(items) do amount = amount + (item.count or 0) end
          end
        end
        local capacity = nil
        if p.size then
          local ok5, sz = pcall(p.size)
          if ok5 and sz then capacity = sz * 64 end
        end
        return amount, capacity
      end
    end
  end

  local fuelReaders = { pump = makeFuelReader("pump"), tank = makeFuelReader("tank") }

  -- Not auto-started: FCS SYNC (a later page task) starts/stops this on demand.
  local cfgserver = CfgServer.new({ read = read, dir = "/" })

  return {
    links = { tel = telLink, ack = ackLink, hb = hbLink },
    cfgLink = cfgLink,
    rx = rx,
    sender = sender,
    hbRx = hbRx,
    engine = engine,
    fuelReaders = fuelReaders,
    cfgserver = cfgserver,
    config = config,
    rebindRelay = rebindRelay,
    uiRev = 0,
    state = { pumpFrac = 0, tankFrac = 0 },
    CH = CH,
    CFG_CH = CFG_CH,
  }
end

-- ===== Modem routing (testable, no sleeping) =====

-- M.routeModem(runtime, ch, msg) -> replyFrame|nil
-- Mirrors ui/main.lua's netLoop routing for tel/ack/health EXACTLY, plus cfgsync on top: a `req`
-- frame on CFG_CH.req is handed to cfgserver:onMessage, and any reply it produces is sent back on
-- cfgLink (and returned, so a test can assert on it directly without capturing a modem transmit).
function M.routeModem(runtime, ch, msg)
  local f = runtime.links.tel:onMessage(ch, msg)
  if f then
    runtime.rx:accept(f)
    return nil
  end

  local a = runtime.links.ack:onMessage(ch, msg)
  if a and a.k == "ack" then
    runtime.sender:ack(a)
    return nil
  end

  local h = runtime.links.hb:onMessage(ch, msg)
  if h and h.k == "hb" then
    runtime.hbRx:mark(os.epoch("utc") / 1000)
    return nil
  end

  local c = runtime.cfgLink:onMessage(ch, msg)
  if c then
    local reply = runtime.cfgserver:onMessage(c)
    if reply then
      runtime.cfgLink:send(reply)
      return reply
    end
  end

  return nil
end

-- ===== Cadence state assembly (pure) =====

-- M.buildState(runtime, now) -> flat cadence.gate-shaped state table.
-- `now` is the ms epoch (os.epoch("utc")), matching what runtime.engine:tick/:status expect;
-- hbRx:up wants seconds, so it's divided down here exactly like ui/main.lua's snapshot() does.
function M.buildState(runtime, now)
  local latest = runtime.rx:latest() or {}
  local e = runtime.engine:status(now)
  return {
    engaged      = latest.engaged,
    gndSafety    = latest.gndSafety,
    positionHold = latest.positionHold,
    mode         = latest.mode,
    linkUp       = runtime.hbRx:up(now / 1000),
    altitude     = latest.altitude,
    vSpeed       = latest.vSpeed,
    heading      = latest.heading,
    loopHz       = latest.loopHz,
    engineMaster = e.master,
    feeding      = e.feeding,
    pulses       = e.pulses,
    nextFeedInMs = e.nextFeedInMs,
    pumpFrac     = runtime.state.pumpFrac,
    tankFrac     = runtime.state.tankFrac,
    uiRev        = runtime.uiRev,
  }
end

-- ===== Scheduled work (in-game only; basalt.schedule per easyhover2_suitex.lua's proven pattern) =====

-- M.startScheduled(basalt, runtime, frames, applyState)
-- Registers five basalt.schedule sleep-loop coroutines -- the SAME composition ui/main.lua ran
-- under parallel.waitForAny, ported one-for-one onto Basalt's own coroutine scheduler (verified
-- against release/basalt-full.lua: b_a.schedule creates a coroutine, resumes it once, and stores
-- its yielded filter; b_a's internal event dispatcher (bca) then resumes any scheduled coroutine
-- whose filter is nil or matches the incoming event, on every basalt.update(...)/basalt.run()
-- pump -- so a plain `os.pullEvent("modem_message")` loop inside a scheduled function receives
-- real modem_message events exactly like it would inside parallel.waitForAny, and `sleep(n)`
-- self-pumps the same way via "timer" events).
--
-- CRITICAL non-blocking discipline (same as ui/main.lua): peripheral polls and long ops live in
-- (a)-(d) below, NEVER in (e) the render-gate -- (e) only builds a quantized signature and calls
-- applyState() when it actually changed, so paint stays off the FCS's shared main-thread budget.
function M.startScheduled(basalt, runtime, frames, applyState)
  applyState = applyState or function() end

  -- (a) modem_message router: telemetry -> rx, ack -> sender, health -> hbRx, cfgsync req -> reply.
  basalt.schedule(function()
    while true do
      local _, _, ch, _replyCh, msg = os.pullEvent("modem_message")
      M.routeModem(runtime, ch, msg)
    end
  end)

  -- (b) engine tick, 0.1s. pcall-guarded like ui/main.lua (the writer inside ui/engine.lua is
  -- already pcall-wrapped for a disconnected/broken relay; this outer guard additionally keeps a
  -- scheduled coroutine that hit an unexpected error alive instead of dying silently forever).
  basalt.schedule(function()
    while true do
      pcall(function() runtime.engine:tick(os.epoch("utc")) end)
      sleep(0.1)
    end
  end)

  -- (c) fuel poll, 0.5s.
  basalt.schedule(function()
    while true do
      runtime.state.pumpFrac = Fuel.read(runtime.fuelReaders.pump, runtime.config.fuel.pump.kind, runtime.config.fuel.pump)
      runtime.state.tankFrac = Fuel.read(runtime.fuelReaders.tank, runtime.config.fuel.tank.kind, runtime.config.fuel.tank)
      sleep(0.5)
    end
  end)

  -- (d) sender retry, 0.25s.
  basalt.schedule(function()
    while true do
      for _, f in ipairs(runtime.sender:tick(0.25)) do runtime.links.tel:send(f) end
      sleep(0.25)
    end
  end)

  -- (e) render gate, ~0.2s: build state, gate on the quantized signature, repaint only on change.
  basalt.schedule(function()
    local lastSig = nil
    while true do
      local now = os.epoch("utc")
      local state = M.buildState(runtime, now)
      local changed, sig = cadence.gate(lastSig, state)
      if changed then
        lastSig = sig
        applyState(state, frames)
      end
      sleep(0.2)
    end
  end)
end

return M
