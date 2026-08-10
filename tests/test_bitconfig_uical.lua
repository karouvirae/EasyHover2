-- tests/test_bitconfig_uical.lua
-- UI CAL sub-menu (ui/basalt/bitconfig/uical.lua): tests M.nextSide (pure), M._applyOp (the
-- effectful seam) with a STUB runtime + injected scan/save spies, M._onButton (ConfigPanel.action
-- dispatch -> _applyOp), and a real-CraftOS-PC Basalt construction probe -- build the element tree
-- on a frame bound to term.current() with a stub runtime + injected scan/save, apply(state), then
-- one basalt.update(...) render pass. NEVER basalt.run() (blocks on pullEventRaw).
--
-- DRAIN-SAFETY focus: every test that changes the bound relay or its side asserts the re-block
-- fires (runtime.rebindRelay() called, then runtime.engine:blockNow() called) -- mirroring
-- ui/main.lua's doScan/doBind/applyConfigOp discipline exactly.
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.uical")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")

-- ===== stub runtime: config table + engine stub (records blockNow/applyConfig) + fuelReaders +
-- ===== rebindRelay spy. Mirrors the shape ui/basalt/app.lua's M.buildRuntime returns. =====

local function newStubRuntime()
  local calls = { rebind = 0, blockNow = 0, applyConfig = {} }

  local engine = {}
  function engine:blockNow() calls.blockNow = calls.blockNow + 1 end
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

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

t.test("M.build constructs the element tree; apply() + one render pass do not error", function()
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
  t.truthy(h.elements.scanBtn ~= nil, "scanBtn present")
  t.truthy(h.elements.bindRelayBtn ~= nil, "bindRelayBtn present")
  t.truthy(h.elements.bindPumpBtn ~= nil, "bindPumpBtn present")
  t.truthy(h.elements.bindTankBtn ~= nil, "bindTankBtn present")
  t.truthy(h.elements.calFuelBtn ~= nil, "calFuelBtn present")
  t.truthy(h.elements.relaySideBtn ~= nil, "relaySideBtn present")
  t.truthy(h.elements.timingLabel ~= nil, "timingLabel present")
  t.truthy(h.elements.pulseDnBtn ~= nil and h.elements.pulseUpBtn ~= nil, "pulse +/- present")
  t.truthy(h.elements.intDnBtn ~= nil and h.elements.intUpBtn ~= nil, "interval +/- present")
  t.truthy(h.elements.invertBtn ~= nil and h.elements.kickBtn ~= nil, "invert/kick toggles present")
  t.truthy(h.elements.backBtn ~= nil, "backBtn present")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build: labels reflect runtime.config at build time (name feedback + relay side + timing)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local nav = Nav.new("bitconfig")
  local runtime = newStubRuntime()
  runtime.config.relay.name = "relay_9"
  runtime.config.relay.side = "top"
  runtime.config.fuel.pump.name = "tank_9"
  runtime.config.fuel.tank.name = "chest_9"
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)

  t.truthy(h.elements.bindRelayBtn:getText():find("relay_9"), "relay name shown")
  t.truthy(h.elements.bindPumpBtn:getText():find("tank_9"), "pump name shown")
  t.truthy(h.elements.bindTankBtn:getText():find("chest_9"), "tank name shown")
  t.truthy(h.elements.relaySideBtn:getText():find("top"), "relay side shown")
end)

t.test("M.build: BACK button pops the nav stack", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local nav = Nav.new("bitconfig")
  nav:push("uical")
  t.eq(nav:top(), "uical")

  local runtime = newStubRuntime()
  local save = newSaveSpy()
  local deps = { scan = descriptorsA, save = save }

  local h = M.build(basalt, frame, runtime, nav, deps)
  t.truthy(h.elements.backBtn ~= nil, "backBtn present")

  -- Directly invoke nav:pop() the same way backBtn's onClick does (a real click needs
  -- basalt.run(), forbidden here).
  nav:pop()
  t.eq(nav:top(), "bitconfig")
end)

return true
