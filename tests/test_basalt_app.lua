-- tests/test_basalt_app.lua
-- Headless probe (REAL CraftOS-PC): Basalt loads from the staged /release/basalt-full.lua,
-- and M.buildFrames constructs a frame per (mocked) monitor + one terminal frame, mirroring
-- honored, and a single basalt.update(...) render pass does not error.
--
-- Task 14 additions: M.buildRuntime/M.routeModem/M.buildState/M.startScheduled -- the reused
-- comms/engine/fuel machinery ported from ui/main.lua onto Basalt's scheduler, with a mock modem
-- + mock file reader so it runs with zero real peripherals.
local t = require("tests.framework")
local M = require("ui.basalt.app")
local protocol  = require("fcs.comms.protocol")
local telemetry = require("fcs.comms.telemetry")
local S         = require("fcs.comms.cfgsync")

-- Minimal mock monitor/term: covers every term method release/basalt-full.lua's render path
-- (render.lua: setCursorPos/blit/setTextColor/setCursorBlink; BaseFrame's "term" setter:
-- setCursorPos presence gate + getSize) invokes, plus the rest of the CC:T monitor surface
-- listed in the task brief so any incidental call is a harmless no-op rather than a crash.
local function newMockMonitor()
  return {
    setCursorPos = function() end,
    write = function() end,
    blit = function() end,
    setTextColor = function() end,
    setTextColour = function() end,
    setBackgroundColor = function() end,
    setBackgroundColour = function() end,
    getSize = function() return 30, 12 end,
    clear = function() end,
    clearLine = function() end,
    setCursorBlink = function() end,
    isColor = function() return true end,
    isColour = function() return true end,
    getTextScale = function() return 1 end,
    setTextScale = function() end,
    scroll = function() end,
    getCursorPos = function() return 1, 1 end,
  }
end

t.test("ensureBasalt loads the vendored release build headless", function()
  local basalt = M.ensureBasalt()
  t.truthy(type(basalt) == "table", "basalt module should be a table")
  t.truthy(type(basalt.createFrame) == "function", "basalt.createFrame should exist")
  t.truthy(type(basalt.getMainFrame) == "function", "basalt.getMainFrame should exist")
  t.truthy(type(basalt.update) == "function", "basalt.update should exist")
end)

t.test("buildFrames creates a frame per assigned monitor (mirrored) plus a terminal frame", function()
  local basalt = M.ensureBasalt()
  local mocks = { mA = newMockMonitor(), mB = newMockMonitor() }
  local wrap = function(name) return mocks[name] end

  local built = M.buildFrames(basalt, { mA = 1, mB = 1 }, { "mA", "mB" }, wrap)

  t.truthy(built.terminal ~= nil, "terminal frame should exist")
  t.truthy(built.monitors.mA ~= nil, "mA frame entry should exist")
  t.truthy(built.monitors.mB ~= nil, "mB frame entry should exist")
  t.truthy(built.monitors.mA.frame ~= nil, "mA should have a frame")
  t.truthy(built.monitors.mB.frame ~= nil, "mB should have a frame")
  t.eq(built.monitors.mA.panelId, 1)
  t.eq(built.monitors.mB.panelId, 1)   -- mirrored onto the same panel id
  t.eq(#built.resolved.unassigned, 0)

  -- ONE render pass across every active frame (terminal + both mocked monitors). NEVER
  -- basalt.run() here -- that blocks on os.pullEventRaw() in a loop.
  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("buildFrames leaves unassigned present monitors out of the assigned set", function()
  local basalt = M.ensureBasalt()
  local mocks = { mA = newMockMonitor(), mC = newMockMonitor() }
  local wrap = function(name) return mocks[name] end

  local built = M.buildFrames(basalt, { mA = 1 }, { "mA", "mC" }, wrap)

  t.truthy(built.monitors.mA ~= nil, "mA should be built")
  t.truthy(built.monitors.mC == nil, "mC has no assignment, should not get a frame")
  t.eq(#built.resolved.unassigned, 1)
  t.eq(built.resolved.unassigned[1], "mC")
end)

-- ===== Task 14: buildRuntime / routeModem / buildState / startScheduled =====

local CH, CFG_CH = M.CH, M.CFG_CH

-- Mock modem: covers everything modemlib.wrap needs (open, transmit) and records every transmit
-- so a test can assert a cfgsync reply actually went out, not just that routeModem returned one.
local function newMockModem()
  local sent = {}
  local dev = {
    open = function() end,
    isWireless = function() return false end,
  }
  dev.transmit = function(tx, rx, msg) sent[#sent + 1] = { tx = tx, rx = rx, msg = msg } end
  dev._sent = sent
  return dev
end

local function newRuntime(files)
  local modem = newMockModem()
  local runtime = M.buildRuntime({
    modem = modem,
    wrap = function() return {} end,          -- no relay/fuel peripherals present in this probe
    read = function(p) return (files or {})[p] end,
  })
  return runtime, modem
end

t.test("buildRuntime wires comms/engine/fuel/cfgsync with injected deps, no real peripherals", function()
  local runtime = newRuntime()
  t.truthy(runtime.links ~= nil and runtime.links.tel ~= nil, "tel link present")
  t.truthy(runtime.links.ack ~= nil, "ack link present")
  t.truthy(runtime.links.hb ~= nil, "hb link present")
  t.truthy(runtime.cfgLink ~= nil, "cfgLink present")
  t.truthy(runtime.rx ~= nil, "rx present")
  t.truthy(runtime.sender ~= nil, "sender present")
  t.truthy(runtime.hbRx ~= nil, "hbRx present")
  t.truthy(runtime.engine ~= nil, "engine present")
  t.truthy(runtime.fuelReaders ~= nil and runtime.fuelReaders.pump and runtime.fuelReaders.tank, "fuelReaders present")
  t.truthy(runtime.cfgserver ~= nil, "cfgserver present")
  t.truthy(runtime.cfgserver:running() == false, "cfgserver NOT auto-started")
  t.eq(runtime.uiRev, 0)
  -- UI logger present + a no-op setLogStatus (real overlay wired only in M.run, in-game).
  t.truthy(runtime.uilog ~= nil, "uilog present")
  t.eq(runtime.uilog.enabled, false, "logging off by default (no _G.EH2_UILOG / deps.uilog)")
  t.eq(type(runtime.setLogStatus), "function", "setLogStatus stub present")
end)

t.test("buildRuntime arms the UI logger when deps.uilog is true", function()
  local modem = newMockModem()
  local runtime = M.buildRuntime({ modem = modem, wrap = function() return {} end,
    read = function() return nil end, uilog = true })
  t.eq(runtime.uilog.enabled, true, "deps.uilog=true arms logging")
  runtime.uilog:event("TEST", "hello", 1000)
  t.eq(#runtime.uilog:rows(), 1, "events record when armed")
end)

t.test("routeModem accepts a telemetry frame into rx", function()
  local runtime = newRuntime()
  local tx = telemetry.Tx.new()
  local frame = tx:frame({ engaged = true, altitude = 42, mode = "HOVER" })
  M.routeModem(runtime, CH.telemetry, protocol.encode(frame))
  local latest = runtime.rx:latest()
  t.truthy(latest ~= nil, "rx has a snapshot")
  t.eq(latest.altitude, 42)
  t.eq(latest.mode, "HOVER")
end)

t.test("routeModem acks the pending sender frame", function()
  local runtime = newRuntime()
  local cmdFrame = runtime.sender:send({ k = "engage" })
  t.truthy(runtime.sender.pending[cmdFrame.id] ~= nil, "pending before ack")
  M.routeModem(runtime, CH.ack, protocol.encode({ k = "ack", sid = cmdFrame.sid, id = cmdFrame.id }))
  t.eq(runtime.sender.pending[cmdFrame.id], nil, "ack clears pending")
end)

t.test("routeModem marks health rx up", function()
  local runtime = newRuntime()
  t.eq(runtime.hbRx:up(os.epoch("utc") / 1000), false, "no heartbeat yet -> down")
  M.routeModem(runtime, CH.health, protocol.encode({ k = "hb", t = os.epoch("utc") / 1000 }))
  t.eq(runtime.hbRx:up(os.epoch("utc") / 1000), true, "heartbeat -> up")
end)

t.test("routeModem answers a cfgsync req when the server is running and holds the file", function()
  local runtime, modem = newRuntime({ ["/eh2_tuning.tbl"] = "TUNING-BODY" })
  runtime.cfgserver:start()
  local reply = M.routeModem(runtime, CFG_CH.req, protocol.encode(S.req("sid1", "tuning")))
  t.truthy(reply ~= nil, "a reply frame should come back")
  t.eq(reply.body, "TUNING-BODY", "reply carries the raw file body string")
  t.eq(#modem._sent, 1, "the reply was actually transmitted on the modem")
end)

t.test("routeModem stays silent for cfgsync req when the server is stopped", function()
  local runtime, modem = newRuntime({ ["/eh2_tuning.tbl"] = "TUNING-BODY" })
  -- server never started
  local reply = M.routeModem(runtime, CFG_CH.req, protocol.encode(S.req("sid1", "tuning")))
  t.eq(reply, nil, "stopped server -> no reply")
  t.eq(#modem._sent, 0, "nothing transmitted")
end)

t.test("buildState assembles the flat cadence keys from telemetry + engine + fuel + uiRev", function()
  local runtime = newRuntime()
  local tx = telemetry.Tx.new()
  local frame = tx:frame({
    engaged = true, gndSafety = false, positionHold = false, mode = "HOVER",
    altitude = 12.3, vSpeed = 0.5, heading = 90, loopHz = 20,
  })
  M.routeModem(runtime, CH.telemetry, protocol.encode(frame))
  runtime.state.pumpFrac = 0.5
  runtime.state.tankFrac = 0.75
  runtime.uiRev = 3

  local state = M.buildState(runtime, os.epoch("utc"))
  t.eq(state.engaged, true)
  t.eq(state.gndSafety, false)
  t.eq(state.mode, "HOVER")
  t.eq(state.altitude, 12.3)
  t.eq(state.vSpeed, 0.5)
  t.eq(state.heading, nil, "heading is nav-magnet-table sourced, NOT the FCS telemetry heading")
  t.eq(state.loopHz, 20)
  t.eq(state.linkUp, false, "no heartbeat received -> linkUp false")
  t.eq(state.engineMaster, false, "masterDefault is false")
  t.eq(state.feeding, false)
  t.eq(state.pumpFrac, 0.5)
  t.eq(state.tankFrac, 0.75)
  t.eq(state.uiRev, 3)
end)

t.test("routeModem stores a navfix relay (fix present) into runtime.nav", function()
  local runtime = newRuntime()
  local frame = { k = "navfix", fix = { x = 10, y = 82, z = -20, age = 0, source = "gps", nBeacons = 4, quality = 1.0 },
    gs = 12.5, at = 1000 }
  local reply = M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(reply, nil, "navfix is a fire-and-forget relay, no reply frame")
  t.eq(runtime.nav.gpsAlt, 82)
  t.eq(runtime.nav.tas, 12.5)
  t.eq(runtime.nav.fixOk, true)
  t.eq(runtime.nav.at, nil, "navfix does NOT touch the heading-freshness clock (that's navhdg's job)")
end)

t.test("routeModem stores a navfix relay (no fix) into runtime.nav", function()
  local runtime = newRuntime()
  local frame = { k = "navfix", fix = nil, heading = nil, compass = nil, gs = nil, at = 1000 }
  M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(runtime.nav.gpsAlt, nil)
  t.eq(runtime.nav.tas, nil)
  t.eq(runtime.nav.fixOk, false)
end)

t.test("routeModem stores a fast navhdg relay: heading + compass + freshness clock", function()
  local runtime = newRuntime()
  local frame = { k = "navhdg", heading = 123, compass = "SE", at = 1000 }
  local reply = M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(reply, nil, "navhdg is a fire-and-forget relay, no reply frame")
  t.eq(runtime.nav.heading, 123, "nav bearing stored")
  t.eq(runtime.nav.compass, "SE", "compass stored")
  t.truthy(runtime.nav.at ~= nil, "navhdg stamps the heading-freshness clock")
end)

t.test("routeModem stores craft x/z from a navfix relay (for waypoint targeting)", function()
  local runtime = newRuntime()
  local frame = { k = "navfix", fix = { x = 100, y = 64, z = -200 }, gs = 5, at = 1 }
  M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(runtime.nav.fixX, 100); t.eq(runtime.nav.fixZ, -200); t.eq(runtime.nav.gpsAlt, 64)
end)

t.test("routeModem feeds a wpt_store reply (ch 109) into the wptClient cache", function()
  local runtime = newRuntime()
  t.truthy(runtime.wptClient ~= nil, "buildRuntime wired the NAV store sync client")
  local frame = { k = "wpt_store",
    store = { waypoints = { { name = "Home", x = 1, y = 2, z = 3, type = "base" } }, routes = {} }, rev = 5 }
  M.routeModem(runtime, 109, protocol.encode(frame))
  t.eq(runtime.wptClient.online, true)
  t.eq(runtime.wptClient.rev, 5)
  t.eq(#runtime.wptClient.store.waypoints, 1)
end)

t.test("buildState heading comes from a FRESH nav relay, ignoring FCS telemetry heading", function()
  local runtime = newRuntime()
  M.routeModem(runtime, CH.telemetry, protocol.encode(telemetry.Tx.new():frame({ heading = 90 })))
  local now = os.epoch("utc")
  runtime.nav.heading = 123
  runtime.nav.at = now
  local state = M.buildState(runtime, now)
  t.eq(state.heading, 123, "display heading is the nav magnet-table bearing")
end)

t.test("buildState heading is nil when the nav relay is stale (nav pc down)", function()
  local runtime = newRuntime()
  runtime.nav.heading = 123
  runtime.nav.at = 0
  local state = M.buildState(runtime, M.NAV_HEADING_MAX_AGE_MS + 1)  -- just past the stale window
  t.eq(state.heading, nil, "stale nav -> no heading (tape shows ---)")
end)

t.test("buildState heading is nil when no nav relay has ever arrived", function()
  local runtime = newRuntime()
  local state = M.buildState(runtime, os.epoch("utc"))
  t.eq(state.heading, nil)
end)

t.test("app loads + startScheduled registers scheduled work + one render pass, no error, no basalt.run()", function()
  local basalt = M.ensureBasalt()
  local mocks = { mA = newMockMonitor() }
  local wrap = function(name) return mocks[name] end
  local built = M.buildFrames(basalt, { mA = "fcs" }, { "mA" }, wrap)

  local runtime = newRuntime()
  local applied = 0

  local ok, err = pcall(function()
    M.startScheduled(basalt, runtime, built, function() applied = applied + 1 end)
    basalt.update("timer", -1)
  end)
  t.truthy(ok, "startScheduled + one render pass should not error: " .. tostring(err))
end)

t.test("logging-armed: status overlay (z=1000) + input logger run clean and record events (real basalt)", function()
  local basalt = M.ensureBasalt()
  local mocks = { mA = newMockMonitor() }
  local built = M.buildFrames(basalt, { mA = "fcs" }, { "mA" }, function(name) return mocks[name] end)
  local runtime = M.buildRuntime({ modem = newMockModem(), wrap = function() return {} end,
    read = function() return nil end, uilog = true })

  local ok, err = pcall(function()
    -- Mirror M.run's overlay wiring: a high-z status label on the terminal frame + the setter.
    local tw, th = built.terminal:getSize()
    local statusLabel = built.terminal:addLabel({ x = 1, y = th, width = tw, height = 1, autoSize = false,
      z = 1000, background = colors.black, foreground = colors.lime, text = "LOG on  P:upload" })
    runtime.setLogStatus = function(s) statusLabel:setText(tostring(s)) end
    runtime.setLogStatus("LOG .. uploading")               -- exercise the setter path

    M.startScheduled(basalt, runtime, built, function() end)
    basalt.update("timer", -1)                             -- render + resume the sleep loops once
    basalt.update("mouse_click", 1, 2, 3)                  -- raw-input logger should record this
  end)
  t.truthy(ok, "logging-armed startScheduled + z-overlay must not error: " .. tostring(err))

  local joined = table.concat(runtime.uilog:rows(), "\n")
  t.truthy(joined:find("INPUT", 1, true), "raw input was logged while armed:\n" .. joined)
end)
