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
  t.eq(state.heading, 90)
  t.eq(state.loopHz, 20)
  t.eq(state.linkUp, false, "no heartbeat received -> linkUp false")
  t.eq(state.engineMaster, false, "masterDefault is false")
  t.eq(state.feeding, false)
  t.eq(state.pumpFrac, 0.5)
  t.eq(state.tankFrac, 0.75)
  t.eq(state.uiRev, 3)
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
