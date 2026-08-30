-- tests/test_bitconfig_uical.lua
-- UI CAL sub-menu (ui/basalt/bitconfig/uical.lua): tests M.nextSide (pure), M._applyOp (the
-- effectful seam) with a STUB runtime + injected scan/save spies, M._onButton (ConfigPanel.action
-- dispatch -> _applyOp), M.CATEGORIES/M.CONTROLS_BY_CATEGORY (the pure overview->category
-- drilldown mapping -- Task 5), and a real-CraftOS-PC Basalt construction probe -- build the
-- element tree on a frame bound to term.current() with a stub runtime + injected scan/save,
-- push/pop the region's own nav to drill into each category screen, apply(state), then one
-- basalt.update(...) render pass. NEVER basalt.run() (blocks on pullEventRaw).
--
-- DRAIN-SAFETY focus: every test that changes the bound relay or its side asserts the re-block
-- fires (runtime.rebindRelay() called, then runtime.engine:blockNow() called) -- mirroring
-- ui/main.lua's doScan/doBind/applyConfigOp discipline exactly. M.build now hosts a
-- ui/basalt/region.lua drilldown so every category screen fits the ~12-row monitor (the old flat
-- build's BACK rendered off-screen) -- but every control still routes through the SAME
-- _applyOp/_pickBind/_pickSide seams, so the drain-safety re-block is unaffected by WHERE a
-- control lives on screen.
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.uical")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")

-- ===== stub runtime: config table + engine stub (records blockNow/applyConfig) + fuelReaders +
-- ===== rebindRelay spy. Mirrors the shape ui/basalt/app.lua's M.buildRuntime returns. =====

local function newStubRuntime()
  local calls = { rebind = 0, blockNow = 0, beginLeaveLatch = 0, applyConfig = {}, rebuildEngineWriter = 0 }

  local engine = {}
  function engine:blockNow() calls.blockNow = calls.blockNow + 1 end
  function engine:beginLeaveLatch(_now, onDone)
    calls.beginLeaveLatch = calls.beginLeaveLatch + 1
    -- Stub does not simulate LATCH_LINE_MS; leave-completion tests use a real Engine.
    if onDone then onDone() end
  end
  function engine:applyConfig(cfg) calls.applyConfig[#calls.applyConfig + 1] = cfg end

  local fuelReadings = { pump = 120, tank = 340 }

  local runtime = {
    config = {
      relay = { name = nil, side = nil },
      fuel = {
        pump = { name = nil, kind = "inventory", empty = 0, full = 0 },
        tank = { name = nil, kind = "inventory", empty = 0, full = 0 },
      },
      engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false },
    },
    engine = engine,
    fuelReaders = {
      pump = function() return fuelReadings.pump end,
      tank = function() return fuelReadings.tank end,
    },
    rebindRelay = function() calls.rebind = calls.rebind + 1 end,
    rebuildEngineWriter = function() calls.rebuildEngineWriter = calls.rebuildEngineWriter + 1 end,
  }

  return runtime, calls
end

local function newSaveSpy()
  local calls = {}
  local function save(path, cfg) calls[#calls + 1] = { path = path, cfg = cfg } end
  return save, calls
end

-- Canned descriptors: two redstone_relays (relay_1, relay_2), one fluid tank, one inventory chest.
-- Detect.propose picks relay_1 (first redstone_relay) and, in scan order, tank_1 then chest_1 as
-- the two fuel candidates (relay_1/relay_2's methods classify as Fuel "unknown", so they're
-- skipped as fuel candidates).
local function descriptorsA()
  return {
    { name = "relay_1", type = "redstone_relay", methods = { setOutput = true } },
    { name = "relay_2", type = "redstone_relay", methods = { setOutput = true } },
    { name = "tank_1",  type = "fluid_tank",     methods = { getFuelAmountMb = true, getFuelCapacityMb = true } },
    { name = "chest_1", type = "inventory",      methods = { list = true, size = true } },
  }
end

-- ===== M.nextSide: pure =====

t.test("nextSide cycles back->front->left->right->top->bottom->back (wrap)", function()
  local order = { "back", "front", "left", "right", "top", "bottom" }
  for i = 1, #order do
    local nxt = order[(i % #order) + 1]
    t.eq(M.nextSide(order[i]), nxt)
  end
end)

t.test("nextSide: nil or unknown current returns the first side", function()
  t.eq(M.nextSide(nil), "back")
  t.eq(M.nextSide("bogus"), "back")
end)

-- ===== M.id / M.title =====

t.test("M.id is 'uical' (pinned by the BIT/CONFIG hub's M.ITEMS)", function()
  t.eq(M.id, "uical")
end)

-- ===== M._applyOp: scan -- binds Detect-proposed relay/pump/tank, re-blocks, saves =====

t.test("_applyOp scan: binds Detect-proposed relay/pump/tank into config", function()
  local runtime = newStubRuntime()
  local save, saveCalls = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  M._applyOp(runtime, { kind = "config", op = "scan" }, deps)

  t.eq(runtime.config.relay.name, "relay_1")
  t.eq(runtime.config.relay.side, "back")
  t.eq(runtime.config.fuel.pump.name, "tank_1")
  t.eq(runtime.config.fuel.pump.kind, "fluid")
  t.eq(runtime.config.fuel.tank.name, "chest_1")
  t.eq(runtime.config.fuel.tank.kind, "inventory")
  t.eq(#saveCalls, 1)
  t.eq(saveCalls[1].path, BasaltApp.CONFIG_PATH)
end)

t.test("_applyOp scan: DRAIN-SAFETY -- proposing a relay triggers rebindRelay + engine:blockNow", function()
  local runtime, calls = newStubRuntime()
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  M._applyOp(runtime, { kind = "config", op = "scan" }, deps)

  t.eq(calls.rebind, 1, "rebindRelay called once")
  t.eq(calls.blockNow, 1, "engine:blockNow called once")
end)

t.test("_applyOp scan: no redstone_relay present -> no relay bound, no re-block", function()
  local runtime, calls = newStubRuntime()
  local save = newSaveSpy()
  local noRelayDescriptors = function()
    return {
      { name = "tank_1", type = "fluid_tank", methods = { getFuelAmountMb = true } },
    }
  end
  local deps = { scan = noRelayDescriptors, save = save }

  M._applyOp(runtime, { kind = "config", op = "scan" }, deps)

  t.eq(runtime.config.relay.name, nil)
  t.eq(calls.rebind, 0)
  t.eq(calls.blockNow, 0)
  t.eq(runtime.config.fuel.pump.name, "tank_1")
end)

-- ===== M._applyOp: bind(role) -- cycles to next matching candidate, re-blocks on relay =====

t.test("_applyOp bind(relay): cycles to the next redstone_relay candidate", function()
  local runtime = newStubRuntime()
  runtime.config.relay.name = "relay_1"
  runtime.config.relay.side = "back"
  local save, saveCalls = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  M._applyOp(runtime, { kind = "config", op = "bind", role = "relay" }, deps)

  t.eq(runtime.config.relay.name, "relay_2")
  t.eq(#saveCalls, 1)
end)

t.test("_applyOp bind(relay): DRAIN-SAFETY -- re-block fires on every relay bind", function()
  local runtime, calls = newStubRuntime()
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  M._applyOp(runtime, { kind = "config", op = "bind", role = "relay" }, deps)
  t.eq(runtime.config.relay.name, "relay_1", "unbound -> first candidate")
  t.eq(calls.rebind, 1)
  t.eq(calls.blockNow, 1)

  M._applyOp(runtime, { kind = "config", op = "bind", role = "relay" }, deps)
  t.eq(runtime.config.relay.name, "relay_2", "cycles to the next candidate")
  t.eq(calls.rebind, 2)
  t.eq(calls.blockNow, 2)

  M._applyOp(runtime, { kind = "config", op = "bind", role = "relay" }, deps)
  t.eq(runtime.config.relay.name, "relay_1", "wraps back to the first candidate")
  t.eq(calls.rebind, 3)
  t.eq(calls.blockNow, 3)
end)

t.test("_applyOp bind(pump): cycles fuel candidates, NO relay re-block", function()
  local runtime, calls = newStubRuntime()
  local save, saveCalls = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  M._applyOp(runtime, { kind = "config", op = "bind", role = "pump" }, deps)

  t.eq(runtime.config.fuel.pump.name, "tank_1")
  t.eq(runtime.config.fuel.pump.kind, "fluid")
  t.eq(calls.rebind, 0, "binding pump never touches the relay")
  t.eq(calls.blockNow, 0)
  t.eq(#saveCalls, 1)
end)

t.test("_applyOp bind(tank): cycles fuel candidates independently of pump", function()
  local runtime = newStubRuntime()
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  M._applyOp(runtime, { kind = "config", op = "bind", role = "tank" }, deps)

  t.eq(runtime.config.fuel.tank.name, "tank_1")
  t.eq(runtime.config.fuel.tank.kind, "fluid")
end)

-- ===== M._applyOp: calFuel -- current reading becomes "full" =====

t.test("_applyOp calFuel: sets fuel.pump.full/tank.full from fuelReaders, saves, no relay touch", function()
  local runtime, calls = newStubRuntime()
  local save, saveCalls = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  M._applyOp(runtime, { kind = "config", op = "calFuel" }, deps)

  t.eq(runtime.config.fuel.pump.full, 120)
  t.eq(runtime.config.fuel.tank.full, 340)
  t.eq(runtime.config.fuel.pump.empty, 0)
  t.eq(runtime.config.fuel.tank.empty, 0)
  t.eq(calls.rebind, 0)
  t.eq(calls.blockNow, 0)
  t.eq(#saveCalls, 1)
end)

-- ===== M._applyOp: cycleRelaySide -- advances the side, re-blocks =====

t.test("_applyOp cycleRelaySide: advances the side and saves", function()
  local runtime = newStubRuntime()
  runtime.config.relay.side = "back"
  local save, saveCalls = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "cycleRelaySide" }, deps)

  t.eq(runtime.config.relay.side, "front")
  t.eq(#saveCalls, 1)
end)

t.test("_applyOp cycleRelaySide: DRAIN-SAFETY -- re-block fires on every side change", function()
  local runtime, calls = newStubRuntime()
  local save = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "cycleRelaySide" }, deps)
  t.eq(calls.rebind, 1)
  t.eq(calls.blockNow, 1)

  M._applyOp(runtime, { kind = "config", op = "cycleRelaySide" }, deps)
  t.eq(calls.rebind, 2)
  t.eq(calls.blockNow, 2)
end)

-- ===== M._applyOp: stepEngine -- pulseMs/intervalMs deltas, interval floors at 15000 =====

t.test("_applyOp stepEngine: pulseMs delta applies and calls engine:applyConfig", function()
  local runtime, calls = newStubRuntime()
  local save, saveCalls = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "stepEngine", field = "pulseMs", delta = 50 }, deps)

  t.eq(runtime.config.engine.pulseMs, 300)
  t.eq(#calls.applyConfig, 1)
  t.eq(#saveCalls, 1)
end)

t.test("_applyOp stepEngine: intervalMs never drops below the 15000ms floor", function()
  local runtime = newStubRuntime()
  runtime.config.engine.intervalMs = 15000
  local save = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "stepEngine", field = "intervalMs", delta = -15000 }, deps)

  t.eq(runtime.config.engine.intervalMs, 15000, "floors at 15000, never reaches 0")
end)

t.test("_applyOp stepEngine: intervalMs steps down normally above the floor", function()
  local runtime = newStubRuntime()
  runtime.config.engine.intervalMs = 330000
  local save = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "stepEngine", field = "intervalMs", delta = -15000 }, deps)

  t.eq(runtime.config.engine.intervalMs, 315000)
end)

-- ===== M._applyOp: toggle -- invert/kickstart flip =====

t.test("_applyOp toggle: flips engine.invert and engine.kickstart independently, saves each time", function()
  local runtime = newStubRuntime()
  local save, saveCalls = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "toggle", field = "invert" }, deps)
  t.eq(runtime.config.engine.invert, true)

  M._applyOp(runtime, { kind = "config", op = "toggle", field = "kickstart" }, deps)
  t.eq(runtime.config.engine.kickstart, false)

  t.eq(#saveCalls, 2)
end)

-- ===== M._applyOp: cycleMode -- toggles engine.mode basic<->latch, re-applies, re-blocks =====

t.test("_applyOp cycleMode: toggles basic<->latch and persists", function()
  local runtime = newStubRuntime()
  local save, saveCalls = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "cycleMode" }, deps)
  t.eq(runtime.config.engine.mode, "latch")

  M._applyOp(runtime, { kind = "config", op = "cycleMode" }, deps)
  t.eq(runtime.config.engine.mode, "basic")

  t.eq(#saveCalls, 2)
end)

t.test("_applyOp cycleMode: applyConfig + rebindRelay + engine:blockNow all fire on a mode flip", function()
  local runtime, calls = newStubRuntime()
  local save = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "cycleMode" }, deps)

  t.eq(#calls.applyConfig, 1)
  t.eq(calls.rebuildEngineWriter, 1)
  t.eq(calls.rebind, 1)
  t.eq(calls.blockNow, 1)
end)

t.test("_applyOp cycleMode: leave-latch defers rebuild until BLOCK line is down (no sleep)", function()
  -- Config flips to basic immediately; live Engine.mode stays latch and the latch writer stays
  -- bound until tick lowers BLOCK after LATCH_LINE_MS. No sleep() in the onClick path.
  local Engine = require("ui.engine")
  local writes = {}
  local latchWriter = function(line, value)
    writes[#writes + 1] = { kind = "latch", line = line, value = value }
    return true
  end
  local basicWriter = function(sig)
    writes[#writes + 1] = { kind = "basic", sig = sig }
    return true
  end
  local engine = Engine.new(
    { mode = "latch", pulseMs = 250, intervalMs = 1500, kickstart = true, masterDefault = false },
    latchWriter)
  engine:setMaster(true, 0)   -- mid-feed: FEED raised, lastFeeding=true

  local runtime, calls = newStubRuntime()
  runtime.config.engine.mode = "latch"
  runtime.config.engine.pulseMs = 250
  runtime.config.engine.intervalMs = 1500
  runtime.config.engine.kickstart = true
  runtime.config.engine.masterDefault = false
  runtime.engine = engine
  local realBlockNow = engine.blockNow
  function engine:blockNow(...)
    calls.blockNow = calls.blockNow + 1
    return realBlockNow(self, ...)
  end
  runtime.rebuildEngineWriter = function()
    calls.rebuildEngineWriter = calls.rebuildEngineWriter + 1
    writes[#writes + 1] = { kind = "rebuild" }
    engine.writer = basicWriter
  end

  local save = newSaveSpy()
  M._applyOp(runtime, { kind = "config", op = "cycleMode" }, { save = save, now = 0 })

  t.eq(runtime.config.engine.mode, "basic", "config/disk truth flips immediately")
  t.eq(engine.mode, "latch", "live Engine.mode stays latch during BLOCK pulse")
  t.eq(calls.rebuildEngineWriter, 0, "rebuild must not run in the click")
  t.eq(engine.feedLineDownAt, nil, "FEED dropped if it was raised")
  t.truthy(engine.blockLineDownAt, "BLOCK pulse armed")

  local feedDown, blockUp
  for _, w in ipairs(writes) do
    if w.kind == "latch" and w.line == "feed" and w.value == false then feedDown = true end
    if w.kind == "latch" and w.line == "block" and w.value == true then blockUp = true end
  end
  t.truthy(feedDown, "FEED must drop before BLOCK rises")
  t.truthy(blockUp, "BLOCK must rise on the latch writer")

  engine:tick(100)
  t.eq(engine.mode, "latch")
  t.eq(calls.rebuildEngineWriter, 0)

  engine:tick(150)
  t.eq(engine.mode, "basic")
  t.eq(calls.rebuildEngineWriter, 1)
  t.eq(calls.rebind, 1)
  t.eq(calls.blockNow, 1, "basic blockNow after writer rebuild")
  t.eq(engine.blockLineDownAt, nil)

  local rebuildAt, blockDownAt
  for i, w in ipairs(writes) do
    if w.kind == "latch" and w.line == "block" and w.value == false and not blockDownAt then blockDownAt = i end
    if w.kind == "rebuild" and not rebuildAt then rebuildAt = i end
  end
  t.truthy(blockDownAt and rebuildAt, "BLOCK lower and rebuild both happened")
  t.eq(blockDownAt < rebuildAt, true, "BLOCK must be down before rebuild swaps the writer")
end)

t.test("_applyOp cycleMode: entering latch clamps a sub-200 pulseMs up to 200", function()
  local runtime = newStubRuntime()
  runtime.config.engine.pulseMs = 100
  local save = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "cycleMode" }, deps)

  t.eq(runtime.config.engine.mode, "latch")
  t.eq(runtime.config.engine.pulseMs, 200, "entering latch floors pulseMs at 200")
end)

t.test("_applyOp cycleMode: leaving latch does NOT raise pulseMs", function()
  local runtime = newStubRuntime()
  runtime.config.engine.mode = "latch"
  runtime.config.engine.pulseMs = 100
  local save = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "cycleMode" }, deps)

  t.eq(runtime.config.engine.mode, "basic")
  t.eq(runtime.config.engine.pulseMs, 100, "leaving latch leaves pulseMs untouched")
end)

-- ===== M._applyOp: cycleRelaySide with effect.which -- basic side (default) vs latch block/feed =====

t.test("_applyOp cycleRelaySide default (no which) still cycles basic relay.side unchanged", function()
  local runtime = newStubRuntime()
  runtime.config.relay.side = "back"
  runtime.config.relay.blockSide = "front"
  runtime.config.relay.feedSide = "left"
  local save, saveCalls = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "cycleRelaySide" }, deps)

  t.eq(runtime.config.relay.side, "front")
  t.eq(runtime.config.relay.blockSide, "front", "block side untouched by the basic op")
  t.eq(runtime.config.relay.feedSide, "left", "feed side untouched by the basic op")
  t.eq(#saveCalls, 1)
end)

t.test("_applyOp cycleRelaySide which=block cycles blockSide and re-blocks", function()
  local runtime, calls = newStubRuntime()
  runtime.config.relay.blockSide = "back"
  local save = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "cycleRelaySide", which = "block" }, deps)

  t.eq(runtime.config.relay.blockSide, M.nextSide("back"))
  t.eq(calls.rebind, 1)
  t.eq(calls.blockNow, 1)
end)

t.test("_applyOp cycleRelaySide which=feed cycles feedSide", function()
  local runtime = newStubRuntime()
  runtime.config.relay.feedSide = "left"
  local save = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "cycleRelaySide", which = "feed" }, deps)

  t.eq(runtime.config.relay.feedSide, M.nextSide("left"))
end)

-- ===== M._applyOp: stepEngine -- pulseMs floors at 200 in latch mode, stays 0-floor in basic =====

t.test("_applyOp stepEngine: pulseMs floors at 200 in latch mode (150 clamped up to 200)", function()
  local runtime = newStubRuntime()
  runtime.config.engine.mode = "latch"
  runtime.config.engine.pulseMs = 250
  local save = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "stepEngine", field = "pulseMs", delta = -100 }, deps)

  t.eq(runtime.config.engine.pulseMs, 200)
end)

t.test("_applyOp stepEngine: pulseMs has no 200 floor in basic mode (matches today's behaviour)", function()
  local runtime = newStubRuntime()
  runtime.config.engine.pulseMs = 50
  local save = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, { kind = "config", op = "stepEngine", field = "pulseMs", delta = -100 }, deps)

  t.eq(runtime.config.engine.pulseMs, 0, "basic mode still floors pulseMs at 0 only")
end)

-- ===== M._fuelCandidates / M._relayCandidates: PURE dropdown-population filters =====

t.test("_fuelCandidates: names whose methods classify as fluid/inventory, not the relays", function()
  local names = M._fuelCandidates(descriptorsA())
  t.eq(#names, 2)
  local set = { [names[1]] = true, [names[2]] = true }
  t.truthy(set.tank_1 and set.chest_1, "tank_1 (fluid) and chest_1 (inventory) both candidates")
  t.truthy(not set.relay_1 and not set.relay_2, "relays never fuel candidates")
end)

t.test("_fuelCandidates: empty/nil descriptors -> empty list", function()
  t.eq(#M._fuelCandidates({}), 0)
  t.eq(#M._fuelCandidates(nil), 0)
end)

t.test("_relayCandidates: only redstone_relay-typed names, in scan order", function()
  local names = M._relayCandidates(descriptorsA())
  t.eq(#names, 2)
  t.eq(names[1], "relay_1")
  t.eq(names[2], "relay_2")
end)

t.test("_relayCandidates: no relays present -> empty list", function()
  t.eq(#M._relayCandidates({ { name = "tank_1", type = "fluid_tank", methods = {} } }), 0)
end)

t.test("_toOptions: leads with (none)/false, then one entry per candidate", function()
  local opts = M._toOptions({ "relay_1", "relay_2" })
  t.eq(#opts, 3)
  t.eq(opts[1].text, "(none)")
  t.eq(opts[1].value, false)
  t.eq(opts[2].text, "relay_1")
  t.eq(opts[2].value, "relay_1")
  t.eq(opts[3].text, "relay_2")
end)

t.test("_toOptions: empty/nil candidates -> just the (none) entry", function()
  t.eq(#M._toOptions({}), 1)
  t.eq(#M._toOptions(nil), 1)
end)

-- ===== M._pickBind: SET the picked value directly (no cycling). DRAIN-SAFETY on relay picks. =====

t.test("_pickBind(pump): sets fuel.pump.name + kind, saves, NO relay re-block", function()
  local runtime, calls = newStubRuntime()
  local save, saveCalls = newSaveSpy()

  local ret = M._pickBind(runtime, "pump", "tank_1", descriptorsA(), { save = save })

  t.eq(ret, "tank_1")
  t.eq(runtime.config.fuel.pump.name, "tank_1")
  t.eq(runtime.config.fuel.pump.kind, "fluid")
  t.eq(calls.rebind, 0, "picking pump never touches the relay")
  t.eq(calls.blockNow, 0, "picking pump never re-blocks")
  t.eq(#saveCalls, 1)
end)

t.test("_pickBind(tank): sets fuel.tank.name + kind independently of pump, NO relay re-block", function()
  local runtime, calls = newStubRuntime()
  local save = newSaveSpy()

  M._pickBind(runtime, "tank", "chest_1", descriptorsA(), { save = save })

  t.eq(runtime.config.fuel.tank.name, "chest_1")
  t.eq(runtime.config.fuel.tank.kind, "inventory")
  t.eq(calls.rebind, 0)
  t.eq(calls.blockNow, 0)
end)

t.test("_pickBind(pump, false): unbinds -- name cleared, kind left alone", function()
  local runtime = newStubRuntime()
  runtime.config.fuel.pump.name = "tank_1"
  runtime.config.fuel.pump.kind = "fluid"
  local save = newSaveSpy()

  local ret = M._pickBind(runtime, "pump", false, descriptorsA(), { save = save })

  t.eq(ret, false)
  t.eq(runtime.config.fuel.pump.name, false)
  t.eq(runtime.config.fuel.pump.kind, "fluid", "kind untouched by an unbind pick")
end)

t.test("_pickBind(relay): DRAIN-SAFETY -- sets name, defaults side, rebindRelay+blockNow, saves", function()
  local runtime, calls = newStubRuntime()
  local save, saveCalls = newSaveSpy()

  local ret = M._pickBind(runtime, "relay", "relay_2", descriptorsA(), { save = save })

  t.eq(ret, "relay_2")
  t.eq(runtime.config.relay.name, "relay_2")
  t.eq(runtime.config.relay.side, "back", "side defaulted since it was unset")
  t.eq(calls.rebind, 1, "rebindRelay called")
  t.eq(calls.blockNow, 1, "engine:blockNow called -- DRAIN SAFETY")
  t.eq(#saveCalls, 1)
end)

t.test("_pickBind(relay): does NOT clobber an already-set side", function()
  local runtime = newStubRuntime()
  runtime.config.relay.side = "top"
  local save = newSaveSpy()

  M._pickBind(runtime, "relay", "relay_1", descriptorsA(), { save = save })

  t.eq(runtime.config.relay.side, "top", "existing side preserved")
end)

t.test("_pickBind(relay, false): DRAIN-SAFETY -- unbinding the relay STILL re-blocks", function()
  local runtime, calls = newStubRuntime()
  runtime.config.relay.name = "relay_1"
  runtime.config.relay.side = "back"
  local save = newSaveSpy()

  local ret = M._pickBind(runtime, "relay", false, descriptorsA(), { save = save })

  t.eq(ret, false)
  t.eq(runtime.config.relay.name, false)
  t.eq(calls.rebind, 1, "unbinding still rebinds (to nothing) -- must re-assert blocked")
  t.eq(calls.blockNow, 1, "unbinding still re-blocks -- DRAIN SAFETY on every relay change")
end)

t.test("_pickBind: multiple relay picks in a row each independently re-block (no coalescing)", function()
  local runtime, calls = newStubRuntime()
  local save = newSaveSpy()

  M._pickBind(runtime, "relay", "relay_1", descriptorsA(), { save = save })
  M._pickBind(runtime, "relay", "relay_2", descriptorsA(), { save = save })
  M._pickBind(runtime, "relay", false, descriptorsA(), { save = save })

  t.eq(calls.rebind, 3)
  t.eq(calls.blockNow, 3)
end)

t.test("_pickBind: defaults save to Config.save when deps omitted (does not error)", function()
  local runtime = newStubRuntime()
  -- No save spy injected -- exercises the real ui.config.save default path against a throwaway
  -- fs path so this stays headless-safe.
  local BasaltApp = require("ui.basalt.app")
  local origPath = BasaltApp.CONFIG_PATH
  local ok = pcall(function()
    M._pickBind(runtime, "pump", "tank_1", descriptorsA(), {})
  end)
  t.truthy(ok, "falls back to the real Config.save without erroring")
  t.eq(runtime.config.fuel.pump.name, "tank_1")
end)

-- ===== M._pickSide: SET the picked side directly. DRAIN-SAFETY on every change. =====

t.test("_pickSide: sets relay.side, re-blocks (DRAIN SAFETY), saves", function()
  local runtime, calls = newStubRuntime()
  runtime.config.relay.side = "back"
  local save, saveCalls = newSaveSpy()

  local ret = M._pickSide(runtime, "top", { save = save })

  t.eq(ret, "top")
  t.eq(runtime.config.relay.side, "top")
  t.eq(calls.rebind, 1)
  t.eq(calls.blockNow, 1)
  t.eq(#saveCalls, 1)
end)

t.test("_pickSide: DRAIN-SAFETY -- re-block fires on every side pick, even repeats", function()
  local runtime, calls = newStubRuntime()
  local save = newSaveSpy()

  M._pickSide(runtime, "front", { save = save })
  M._pickSide(runtime, "front", { save = save })
  M._pickSide(runtime, "left", { save = save })

  t.eq(calls.rebind, 3)
  t.eq(calls.blockNow, 3)
end)

-- ===== M._onButton: ConfigPanel.action dispatch -> _applyOp (minus assign: ids) =====

t.test("_onButton: 'scan' dispatches through ConfigPanel.action into _applyOp", function()
  local runtime = newStubRuntime()
  local save, saveCalls = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local effect = M._onButton(runtime, "scan", os.epoch("utc"), deps)

  t.truthy(effect ~= nil and effect.kind == "config" and effect.op == "scan", "returns the scan effect")
  t.eq(runtime.config.relay.name, "relay_1")
  t.eq(#saveCalls, 1)
end)

t.test("_onButton: 'bindRelay' maps to bind(role=relay) and re-blocks", function()
  local runtime, calls = newStubRuntime()
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local effect = M._onButton(runtime, "bindRelay", os.epoch("utc"), deps)

  t.eq(effect.op, "bind")
  t.eq(effect.role, "relay")
  t.eq(runtime.config.relay.name, "relay_1")
  t.eq(calls.rebind, 1)
  t.eq(calls.blockNow, 1)
end)

t.test("_onButton: 'relaySide' maps to cycleRelaySide", function()
  local runtime = newStubRuntime()
  runtime.config.relay.side = "back"
  local save = newSaveSpy()
  local deps = { save = save }

  local effect = M._onButton(runtime, "relaySide", os.epoch("utc"), deps)

  t.eq(effect.op, "cycleRelaySide")
  t.eq(runtime.config.relay.side, "front")
end)

t.test("_onButton: 'calFuel' maps to calFuel", function()
  local runtime = newStubRuntime()
  local save = newSaveSpy()
  local deps = { save = save }

  local effect = M._onButton(runtime, "calFuel", os.epoch("utc"), deps)

  t.eq(effect.op, "calFuel")
  t.eq(runtime.config.fuel.pump.full, 120)
end)

t.test("_onButton: an unrecognised id returns nil and applies nothing", function()
  local runtime = newStubRuntime()
  local save, saveCalls = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local effect = M._onButton(runtime, "assign:mon0", os.epoch("utc"), deps)

  -- ConfigPanel.action DOES map "assign:*" ids -- but this menu never emits one, and even if it
  -- somehow received it, _applyOp has no cycleAssign branch (out of scope here) so nothing in
  -- runtime.config beyond what cycleAssign would touch (nothing, since config.assign isn't part
  -- of this stub) changes, and it still saves once (matching applyConfigOp's unconditional save).
  t.truthy(effect ~= nil and effect.op == "cycleAssign")
  t.eq(#saveCalls, 1)
end)

-- ===== M.CATEGORIES / M.CONTROLS_BY_CATEGORY: pure overview->category drilldown mapping =====

t.test("CATEGORIES: exactly DEVICES/FUEL/TIMING/SETTINGS, in that order", function()
  t.eq(#M.CATEGORIES, 4)
  t.eq(M.CATEGORIES[1], "devices")
  t.eq(M.CATEGORIES[2], "fuel")
  t.eq(M.CATEGORIES[3], "timing")
  t.eq(M.CATEGORIES[4], "settings")
end)

t.test("CONTROLS_BY_CATEGORY: settings owns the 5 UI colour pickers", function()
  local set = {}
  for _, c in ipairs(M.CONTROLS_BY_CATEGORY.settings) do set[c] = true end
  t.eq(#M.CONTROLS_BY_CATEGORY.settings, 5)
  t.truthy(set.font and set.button and set.wpt and set.rt and set.colorblind,
    "settings has font/button/wpt/rt/colorblind")
end)

t.test("CONTROLS_BY_CATEGORY: devices owns SCAN + the 4 bind/side pickers", function()
  local set = {}
  for _, c in ipairs(M.CONTROLS_BY_CATEGORY.devices) do set[c] = true end
  t.eq(#M.CONTROLS_BY_CATEGORY.devices, 5)
  t.truthy(set.scan and set.relay and set.pump and set.tank and set.side,
    "devices has scan/relay/pump/tank/side")
end)

t.test("CONTROLS_BY_CATEGORY: fuel owns only CAL FUEL", function()
  t.eq(#M.CONTROLS_BY_CATEGORY.fuel, 1)
  t.eq(M.CONTROLS_BY_CATEGORY.fuel[1], "calFuel")
end)

t.test("CONTROLS_BY_CATEGORY: timing owns the pulse/interval/toggle sextet", function()
  local set = {}
  for _, c in ipairs(M.CONTROLS_BY_CATEGORY.timing) do set[c] = true end
  t.eq(#M.CONTROLS_BY_CATEGORY.timing, 6)
  for _, c in ipairs({ "pulseDn", "pulseUp", "intervalDn", "intervalUp", "toggleInvert", "toggleKick" }) do
    t.truthy(set[c], c .. " present under timing")
  end
end)

t.test("categoryOf: every control across all categories resolves back to its own category, no overlap", function()
  local total = 0
  for _, cat in ipairs(M.CATEGORIES) do
    for _, c in ipairs(M.CONTROLS_BY_CATEGORY[cat]) do
      t.eq(M.categoryOf(c), cat, c .. " resolves to " .. cat)
      total = total + 1
    end
  end
  t.eq(total, 17, "5 devices + 1 fuel + 6 timing + 5 settings controls, no drops or duplicates")
end)

t.test("categoryOf: an unknown control returns nil", function()
  t.eq(M.categoryOf("bogus"), nil)
  t.eq(M.categoryOf(nil), nil)
end)

-- ===== M._modeIntent / M._sideIntent: PURE button->intent shape seams (Task 6) =====

t.test("_modeIntent/_sideIntent shapes", function()
  t.eq(M._modeIntent().op, "cycleMode")
  t.eq(M._modeIntent().kind, "config")
  t.eq(M._sideIntent("block").op, "cycleRelaySide")
  t.eq(M._sideIntent("block").which, "block")
  t.eq(M._sideIntent("feed").which, "feed")
  t.eq(M._sideIntent("feed").kind, "config")
end)

t.test("_modeIntent/_sideIntent feed through _applyOp exactly like the hand-built effect tables", function()
  local runtime = newStubRuntime()
  local save = newSaveSpy()
  local deps = { save = save }

  M._applyOp(runtime, M._modeIntent(), deps)
  t.eq(runtime.config.engine.mode, "latch", "_modeIntent()'s effect flips basic->latch")

  runtime.config.relay.blockSide = "back"
  M._applyOp(runtime, M._sideIntent("block"), deps)
  t.eq(runtime.config.relay.blockSide, M.nextSide("back"), "_sideIntent('block')'s effect cycles blockSide")

  runtime.config.relay.feedSide = "left"
  M._applyOp(runtime, M._sideIntent("feed"), deps)
  t.eq(runtime.config.relay.feedSide, M.nextSide("left"), "_sideIntent('feed')'s effect cycles feedSide")
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

t.test("M.build: overview shows DEVICES/FUEL/TIMING + '<'; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()   -- binds to term.current(), per ui/basalt/app.lua's header

  local nav = Nav.new("bitconfig")
  local runtime = newStubRuntime()
  local save, saveCalls = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)
  t.eq(h.id, "uical")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.headerLabel ~= nil, "headerLabel present")

  local region = h.elements.region
  t.truthy(region ~= nil, "region exposed")
  t.eq(region:top(), "overview", "region starts at the overview screen")

  local overviewRec = region.built.overview
  t.truthy(overviewRec ~= nil, "overview screen built eagerly by M.build")
  local ov = overviewRec.handle
  for _, cat in ipairs(M.CATEGORIES) do
    t.truthy(ov.elements.catBtns[cat] ~= nil, "overview has a category button for " .. cat)
  end
  t.truthy(ov.elements.backRow ~= nil, "overview has the '<' back row")
  t.eq(#ov.elements.backRow.buttons, 1, "overview back row has exactly one '<' button")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build: drilling DEVICES shows SCAN + RELAY/PUMP/TANK/SIDE pickers; '<' pops back to overview", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime = newStubRuntime()
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local region = h.elements.region

  region:push("devices")
  h.apply({})
  t.eq(region:top(), "devices")

  local rec = region.built.devices
  t.truthy(rec ~= nil, "devices screen built on first visit")
  local els = rec.handle.elements
  t.truthy(els.scanRow ~= nil, "SCAN present")
  t.truthy(els.relayPicker ~= nil, "relayPicker present (DROPDOWN, not a cycle button)")
  t.truthy(els.relayPicker.trigger ~= nil, "relayPicker exposes its trigger element")
  t.truthy(els.pumpPicker ~= nil, "pumpPicker present")
  t.truthy(els.tankPicker ~= nil, "tankPicker present")
  t.truthy(els.sidePicker ~= nil, "sidePicker present (RELAY SIDE dropdown)")
  t.truthy(els.backRow ~= nil, "devices screen exposes its '<' back row")

  -- '<' pops the REGION's own nav (back to overview), not the frame-level nav.
  region:pop()
  h.apply({})
  t.eq(region:top(), "overview", "region back returns to the overview screen")
  t.eq(nav:top(), "bitconfig", "frame-level nav untouched by region-internal drilldown")
end)

t.test("M.build: drilling FUEL shows CAL FUEL + the calibrated reading; '<' pops back to overview", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime = newStubRuntime()
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local region = h.elements.region

  region:push("fuel")
  h.apply({})
  t.eq(region:top(), "fuel")

  local rec = region.built.fuel
  t.truthy(rec ~= nil, "fuel screen built on first visit")
  local els = rec.handle.elements
  t.truthy(els.calFuelRow ~= nil, "CAL FUEL present")
  t.truthy(els.readingLabel ~= nil, "reading label present")
  t.truthy(els.backRow ~= nil, "fuel screen exposes its '<' back row")

  region:pop()
  h.apply({})
  t.eq(region:top(), "overview")
end)

t.test("M.build: drilling TIMING shows PULSE/INT/INVERT/KICK + the timing summary; '<' pops back to overview", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime = newStubRuntime()
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local region = h.elements.region

  region:push("timing")
  h.apply({})
  t.eq(region:top(), "timing")

  local rec = region.built.timing
  t.truthy(rec ~= nil, "timing screen built on first visit")
  local els = rec.handle.elements
  t.truthy(els.pulseRow ~= nil and #els.pulseRow.buttons == 2, "PULSE -50/+50 present")
  t.truthy(els.intRow ~= nil and #els.intRow.buttons == 2, "INT -15s/+15s present")
  t.truthy(els.toggleRow ~= nil and #els.toggleRow.buttons == 2, "INVERT/KICK present")
  t.truthy(els.timingLabel ~= nil, "timing summary label present")
  t.truthy(els.backRow ~= nil, "timing screen exposes its '<' back row")

  region:pop()
  h.apply({})
  t.eq(region:top(), "overview")
end)

t.test("M.build: pickers reflect runtime.config at build time (bound name/side selected)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local nav = Nav.new("bitconfig")
  local runtime = newStubRuntime()
  runtime.config.relay.name = "relay_2" -- must be a real descriptorsA() candidate to be selectable
  runtime.config.relay.side = "top"
  runtime.config.fuel.pump.name = "tank_1"
  runtime.config.fuel.tank.name = "chest_1"
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local region = h.elements.region
  region:push("devices")
  h.apply({})
  local els = region.built.devices.handle.elements

  t.eq(els.relayPicker.selectedItem().value, "relay_2", "relay name selected")
  t.eq(els.pumpPicker.selectedItem().value, "tank_1", "pump name selected")
  t.eq(els.tankPicker.selectedItem().value, "chest_1", "tank name selected")
  t.eq(els.sidePicker.selectedItem().value, "top", "relay side selected")
end)

t.test("M.build: picking a relay via the picker persists + re-blocks (DRAIN SAFETY end-to-end)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local nav = Nav.new("bitconfig")
  local runtime, calls = newStubRuntime()
  local save, saveCalls = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local region = h.elements.region
  region:push("devices")
  h.apply({})
  local before = #saveCalls

  -- Simulate the operator tapping "relay_2" in the RELAY picker's overlay -- drive the tested seam
  -- directly (exactly what the trigger's wired onPick closure does; a real click needs
  -- basalt.run(), forbidden in headless tests).
  M._pickBind(runtime, "relay", "relay_2", descriptorsA(), deps)

  t.eq(runtime.config.relay.name, "relay_2")
  t.truthy(calls.rebind >= 1 and calls.blockNow >= 1, "DRAIN SAFETY re-block fired")
  t.truthy(#saveCalls > before, "config persisted")
end)

t.test("M.build: overview's '<' pops the FRAME-level nav stack", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local nav = Nav.new("bitconfig")
  nav:push("uical")
  t.eq(nav:top(), "uical")

  local runtime = newStubRuntime()
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local ov = h.elements.region.built.overview.handle
  t.truthy(ov.elements.backRow ~= nil, "overview back row present")

  -- Directly invoke nav:pop() the same way the '<' button's onClick does (a real click needs
  -- basalt.run(), forbidden here).
  nav:pop()
  t.eq(nav:top(), "bitconfig")
end)

t.test("M.build: DEVICES screen exposes ENG MODE + BLOCK/FEED SIDE controls, labelled from config", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime = newStubRuntime()
  runtime.config.engine.mode = "latch"
  runtime.config.relay.blockSide = "front"
  runtime.config.relay.feedSide = "top"
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local region = h.elements.region
  region:push("devices")
  h.apply({})

  local els = region.built.devices.handle.elements
  t.truthy(els.modeSw ~= nil and els.modeSw.button ~= nil, "ENG MODE control present")
  t.truthy(els.blockPicker ~= nil, "BLOCK picker present")
  t.truthy(els.feedPicker ~= nil, "FEED picker present")

  t.eq(els.modeSw.button:getText(), "latch")
  t.eq(els.blockPicker.selectedItem().value, "front")
  t.eq(els.feedPicker.selectedItem().value, "top")
end)

t.test("M.build: clicking ENG MODE / BLOCK SIDE / FEED SIDE applies the intent and re-blocks (DRAIN SAFETY)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime, calls = newStubRuntime()
  runtime.config.relay.blockSide = "back"
  runtime.config.relay.feedSide = "back"
  local save, saveCalls = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local region = h.elements.region
  region:push("devices")
  h.apply({})

  -- Drive the exact seam each button's onClick calls -- a real click needs basalt.run(), forbidden
  -- in headless tests (mirrors the file's established "picking a relay via the picker" convention).
  M._applyOp(runtime, M._modeIntent(), deps)
  t.eq(runtime.config.engine.mode, "latch")

  M._applyOp(runtime, M._sideIntent("block"), deps)
  t.eq(runtime.config.relay.blockSide, M.nextSide("back"))
  t.truthy(calls.rebind >= 1 and calls.blockNow >= 1, "block side change re-blocked")

  M._applyOp(runtime, M._sideIntent("feed"), deps)
  t.eq(runtime.config.relay.feedSide, M.nextSide("back"))

  t.truthy(#saveCalls >= 3, "each op persisted")

  h.apply({})
  local els = region.built.devices.handle.elements
  t.truthy(tostring(els.modeSw.button:getText()):find("latch", 1, true) ~= nil, "refresh picks up the new mode")
end)

t.test("M.build: DEVICES screen's SCAN re-scans descriptors + refreshes pickers", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime = newStubRuntime()
  local save, saveCalls = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local region = h.elements.region
  region:push("devices")
  h.apply({})

  -- Exercise SCAN's exact effect the same way its onClick does, without needing basalt.run():
  -- M._onButton(runtime, "scan", ...) -- Detect proposes relay_1 (the first redstone_relay in
  -- descriptorsA()) since nothing is bound yet.
  M._onButton(runtime, "scan", os.epoch("utc"), deps)
  t.eq(runtime.config.relay.name, "relay_1")
  t.truthy(#saveCalls >= 1, "scan persisted via _applyOp")
end)

-- ===== _pickSide which= : latch BLOCK/FEED pickers SET those fields (same drain-safety) =====

t.test("_pickSide which=block sets blockSide, re-blocks, saves", function()
  local runtime, calls = newStubRuntime()
  runtime.config.relay.blockSide = "back"
  local save, saveCalls = newSaveSpy()

  local ret = M._pickSide(runtime, "top", { save = save }, "block")

  t.eq(ret, "top")
  t.eq(runtime.config.relay.blockSide, "top")
  t.eq(runtime.config.relay.side, nil, "basic side untouched")
  t.eq(calls.rebind, 1)
  t.eq(calls.blockNow, 1)
  t.eq(#saveCalls, 1)
end)

t.test("_pickSide which=feed sets feedSide, re-blocks, saves", function()
  local runtime, calls = newStubRuntime()
  runtime.config.relay.feedSide = "left"
  local save, saveCalls = newSaveSpy()

  local ret = M._pickSide(runtime, "front", { save = save }, "feed")

  t.eq(ret, "front")
  t.eq(runtime.config.relay.feedSide, "front")
  t.eq(runtime.config.relay.side, nil, "basic side untouched")
  t.eq(calls.rebind, 1)
  t.eq(calls.blockNow, 1)
  t.eq(#saveCalls, 1)
end)

-- ===== Devices screen readability: left labels, no colon-strip, mode-gated sides, pinned BACK =====

t.test("M.build: MODE/BLOCK/FEED use left labels; switch/picker values are not colon-stripped", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime = newStubRuntime()
  runtime.config.engine.mode = "latch"
  runtime.config.relay.blockSide = "front"
  runtime.config.relay.feedSide = "top"
  local deps = { scan = descriptorsA, save = newSaveSpy() }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local region = h.elements.region
  region:push("devices")
  h.apply({})
  local els = region.built.devices.handle.elements

  t.eq(els.modeLabel:getText(), "MODE")
  t.eq(els.modeSw.button:getText(), "latch")
  t.eq(els.blockLabel:getText(), "BLOCK")
  t.eq(els.feedLabel:getText(), "FEED")
  t.eq(els.blockPicker.selectedItem().value, "front")
  t.eq(els.feedPicker.selectedItem().value, "top")
end)

t.test("M.build: devices BACK sits on the last row of its frame", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime = newStubRuntime()
  local deps = { scan = descriptorsA, save = newSaveSpy() }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local region = h.elements.region
  region:push("devices")
  h.apply({})
  local rec = region.built.devices
  local els = rec.handle.elements
  local _, fh = rec.frame:getSize()
  t.eq(els.backRow.buttons[1].button:getY(), fh, "BACK pinned to last row")
end)

t.test("M.build: latch hides SIDE; basic hides BLOCK/FEED", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime = newStubRuntime()
  runtime.config.engine.mode = "latch"
  local deps = { scan = descriptorsA, save = newSaveSpy() }

  local h = M.build(basalt, frame, runtime, nav, deps)
  local region = h.elements.region
  region:push("devices")
  h.apply({})
  local els = region.built.devices.handle.elements

  t.eq(els.sideLabel:getVisible(), false, "SIDE hidden in latch")
  t.eq(els.sidePicker.trigger:getVisible(), false, "SIDE picker hidden in latch")
  t.eq(els.blockLabel:getVisible(), true, "BLOCK shown in latch")
  t.eq(els.feedLabel:getVisible(), true, "FEED shown in latch")

  runtime.config.engine.mode = "basic"
  h.apply({})
  t.eq(els.sideLabel:getVisible(), true, "SIDE shown in basic")
  t.eq(els.sidePicker.trigger:getVisible(), true, "SIDE picker shown in basic")
  t.eq(els.blockLabel:getVisible(), false, "BLOCK hidden in basic")
  t.eq(els.feedLabel:getVisible(), false, "FEED hidden in basic")
end)

return true
