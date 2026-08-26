-- tests/test_comms_hygiene_e2e.lua
-- E2E (Task 7): assert the NETWORK-TRAFFIC PROFILE the comms-hygiene refactor (Tasks 1-6) locks
-- in, driving REAL production code (ui.basalt.app / nav.runtime), not restated constants:
--   * the UI's scheduled work makes ZERO attitude/velocity/navtable sensor calls (the local
--     attitude poll was deleted in Task 3 -- attitude/heading come from the FCS telemetry
--     snapshot); the fuel poll (3s cadence) is the ONLY peripheral it still reads.
--   * NAV emits `navfix` relay frames but ZERO `navhdg` frames (Task 6 deleted NAV's navtable
--     read + navhdg relay entirely -- heading is read back off the FCS's own telemetry snapshot).
--
-- Technique: a counting `wrap` (peripheral.wrap stand-in) shared across both the UI and NAV
-- sections below, so one set of assertions covers the whole traffic profile. `M.startScheduled`
-- registers Basalt's basalt.schedule sleep-loops; verified against tests/test_basalt_app.lua's own
-- header comment: "b_a.schedule creates a coroutine, resumes it once" -- so calling it ONE time
-- already runs every scheduled function's body up to its first `sleep`/`os.pullEvent` synchronously
-- and for real (the engine tick, the fuel poll, the render-gate's M.buildState, the NAV-store poll
-- all execute their first pass inline; the modem-router and sender-retry loops immediately suspend
-- on os.pullEvent, so they're harmless no-ops here). basalt.update("timer", -1) then resumes every
-- scheduled coroutine once more, mirroring test_basalt_app.lua's own "startScheduled ... one render
-- pass" test -- this is the "simulated ~1s window" the brief asks for; NEVER basalt.run() (blocks
-- on os.pullEventRaw() forever).
local t = require("tests.framework")
local M = require("ui.basalt.app")
local protocol = require("fcs.comms.protocol")
local NavRuntime = require("nav.runtime")
local gpsproto = require("nav.comms.gpsproto")

-- ===== Shared counting wrap =====
-- calls[methodName] += 1 on every method access-and-call through a wrapped "peripheral". Any table
-- key access yields a fresh counting function (so `p.getFuelAmountMb`, `p.tanks`, `p.list`, ... all
-- resolve truthy, matching a real peripheral.wrap()'d table's method-existence checks), and calling
-- it (with any args, any call convention -- dot or colon) records one hit against that method name.
local calls = {}
local function countingWrap(_name)
  return setmetatable({}, { __index = function(_, m)
    return function(...) calls[m] = (calls[m] or 0) + 1 end
  end })
end

-- ===== UI section: mock modem (records every transmit), mirroring tests/test_basalt_app.lua's
-- newMockModem/newRuntime EXACTLY so this probe's runtime is the same real shape M.run() builds. =====
local function newMockModem()
  local sent = {}
  local dev = { open = function() end, isWireless = function() return false end }
  dev.transmit = function(tx, rx, msg) sent[#sent + 1] = { tx = tx, rx = rx, msg = msg } end
  dev._sent = sent
  return dev
end

t.test("UI scheduled work: zero attitude/velocity/navtable sensor calls, fuel still polled", function()
  local basalt = M.ensureBasalt()
  local built = M.buildFrames(basalt, {}, {}, function() end)   -- no monitors, terminal frame only
  local modem = newMockModem()
  local runtime = M.buildRuntime({ modem = modem, wrap = countingWrap, read = function() return nil end })

  -- Configure both fuel roles as real fluid-kind peripherals (name + kind = "fluid") so the fuel
  -- poll's makeFuelReader actually wraps + calls getFuelAmountMb/getFuelCapacityMb, exercising the
  -- ONE peripheral read the UI is still allowed to make -- proving the assertion isn't vacuously
  -- true just because fuel is unconfigured.
  runtime.config.fuel.pump = { name = "pumpTank", kind = "fluid", empty = 0, full = 100 }
  runtime.config.fuel.tank = { name = "mainTank", kind = "fluid", empty = 0, full = 100 }

  -- Registers (a) modem router, (b) engine tick, (c) fuel poll, (d) sender retry, (g) NAV-store
  -- poll, (e) render gate. Each basalt.schedule(...) call resumes its coroutine once IMMEDIATELY,
  -- so (b)/(c)/(e)/(g) already ran their first pass for real by the time this call returns.
  local frameRecs = { terminal = M.newFrameRec(built.terminal, "config") }
  M.startScheduled(basalt, runtime, frameRecs)
  -- One more simulated tick across every scheduled loop (timer-driven resume), same primitive
  -- tests/test_basalt_app.lua's "startScheduled ... one render pass" test uses.
  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "a simulated scheduled-loop tick should not error: " .. tostring(err))

  t.eq(calls.getAngles or 0, 0, "UI must not read the gimbal (attitude poll was deleted, Task 3)")
  t.eq(calls.getVelocity or 0, 0, "UI must not read velocity sensors")
  t.eq(calls.getRelativeAngle or 0, 0, "UI must not read the navtable")
  t.truthy((calls.getFuelAmountMb or 0) >= 1, "UI still reads engine fuel (kept at a 3s cadence)")
end)

-- Independent corroboration of the same invariant at the pure-function seam: M.buildState (the
-- render-gate's body) reads ONLY runtime.rx/engine/nav/state -- never a peripheral -- regardless of
-- what the fuel poll did above. Reuses this file's shared `calls` table; a fresh runtime here has no
-- wrap/peripheral surface at all (buildState never calls one), so this is a structural guarantee,
-- not a coincidence of what the scheduled pass above happened to touch.
t.test("M.buildState makes zero sensor peripheral calls (pure cadence-state assembly)", function()
  local before = calls.getAngles or 0
  local runtime = {
    rx = { latest = function() return { pitch = 0.1, roll = -0.2, surgeVel = 5, compassHeading = 90 } end },
    engine = { status = function() return {} end }, hbRx = { up = function() return true end },
    state = { pumpFrac = 0.4, tankFrac = 0.6 }, nav = {}, uiRev = 1,
  }
  local s = M.buildState(runtime, os.epoch("utc"))
  t.truthy(s ~= nil, "buildState returns a state table")
  t.eq(calls.getAngles or 0, before, "buildState touched no peripheral -- the counting wrap saw nothing new")
end)

-- ===== NAV section: fake wired-modem device (records transmits), mirroring
-- tests/test_nav_runtime.lua's fakeDev/hear helpers EXACTLY. =====
local function fakeDev()
  local d = { sent = {} }
  d.open = function(_ch) end
  d.transmit = function(ch, reply, msg) d.sent[#d.sent + 1] = { ch = ch, reply = reply, msg = msg } end
  return d
end

local function hear(rt, ch, beacon, target)
  local dx, dy, dz = target.x - beacon.x, target.y - beacon.y, target.z - beacon.z
  rt:onModemMessage(ch, ch, gpsproto.encode(beacon), math.sqrt(dx * dx + dy * dy + dz * dz))
end

t.test("NAV relays navfix, never navhdg, and makes zero getRelativeAngle calls", function()
  local wired = fakeDev()
  local rt = NavRuntime.new({
    config = { channel = 65000, relay = { channel = 107 }, thresholds = { maxAgeMs = 3000, minQuality = 0.5 } },
    wiredModem = wired, now = function() return 1000 end,
  })

  -- Drive a full trilateration + relay step (a real modem_message receive per beacon, then :step()
  -- computes+sends the navfix frame onto the wired network) -- NavRuntime.new/onModemMessage/:step
  -- have no wrap/peripheral seam at all post-Task-6 (no navigation_table dependency survives), so
  -- there is nothing here that COULD call getRelativeAngle; the shared `calls` counter proves it.
  local target = { x = 3, y = 4, z = 5 }
  hear(rt, 65000, { id = "A", x = 0,  y = 0,  z = 0 },  target)
  hear(rt, 65000, { id = "B", x = 20, y = 0,  z = 0 },  target)
  hear(rt, 65000, { id = "C", x = 0,  y = 20, z = 0 },  target)
  hear(rt, 65000, { id = "D", x = 0,  y = 0,  z = 20 }, target)
  rt:step()

  -- A telemetry receive: the FCS's own compassHeading snapshot, which is how NAV now gets heading
  -- instead of relaying navhdg itself (Task 6).
  rt:onFcsSnapshot({ compassHeading = 47 })
  t.eq(rt:heading(), 47, "heading comes back off the FCS snapshot, no navtable involved")

  t.truthy(#wired.sent >= 1, "at least one frame was relayed onto the wired network")
  local sawNavfix, sawNavhdg = 0, 0
  for _, s in ipairs(wired.sent) do
    local f = protocol.decode(s.msg)
    if f.k == "navfix" then sawNavfix = sawNavfix + 1 end
    if f.k == "navhdg" then sawNavhdg = sawNavhdg + 1 end
  end
  t.truthy(sawNavfix >= 1, "NAV emits at least one navfix frame")
  t.eq(sawNavhdg, 0, "NAV emits ZERO navhdg frames (Task 6 deleted that relay)")

  t.eq(calls.getRelativeAngle or 0, 0, "NAV must not read the navtable (getRelativeAngle)")
end)

return true
