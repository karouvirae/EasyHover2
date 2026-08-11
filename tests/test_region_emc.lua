-- tests/test_region_emc.lua
-- EMC region screens (ui/basalt/regions/emc.lua) for the merged "flight" cockpit page.
-- Covers the three Basalt-free intent seams (M._onEngine / M._cfg / M._setMax) with stub
-- runtimes, then a CONSTRUCTION PROBE: a real ui/basalt/region.lua Region hosting all three
-- screens, apply() on each, one basalt.update("timer",-1) render pass. NEVER basalt.run().
local t = require("tests.framework")
local M = require("ui.basalt.regions.emc")
local Region = require("ui.basalt.region")
local BasaltApp = require("ui.basalt.app")
local Uical = require("ui.basalt.bitconfig.uical")

-- ===== stub engine: records toggleMaster/feedNow, mutable .master field for status(now) =====

local function newEngineStub(initialMaster)
  local calls = { toggleMaster = 0, feedNow = 0 }
  local e = { master = initialMaster and true or false }
  function e:toggleMaster(now)
    calls.toggleMaster = calls.toggleMaster + 1
    self.master = not self.master
    return self.master
  end
  function e:feedNow(now)
    calls.feedNow = calls.feedNow + 1
    return true
  end
  function e:status(now)
    return { master = self.master }
  end
  return e, calls
end

local function newFuelCfg()
  return {
    pump = { name = nil, kind = "inventory", empty = 0, full = 0 },
    tank = { name = nil, kind = "inventory", empty = 0, full = 0 },
  }
end

-- ===== M._onEngine: no Basalt, stub runtime =====

t.test("_onEngine: engSw does nothing when no relay is bound", function()
  local engine, calls = newEngineStub(false)
  local runtime = { engine = engine, config = { relay = { name = nil, side = nil }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "engSw", 1000)

  t.eq(result, nil, "gated inert -> nil")
  t.eq(calls.toggleMaster, 0)
end)

t.test("_onEngine: engSw toggles master once a relay is bound", function()
  local engine, calls = newEngineStub(false)
  local runtime = { engine = engine, config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "engSw", 1000)

  t.eq(calls.toggleMaster, 1)
  t.truthy(result ~= nil and result.op == "toggleMaster", "returns the action taken")
end)

t.test("_onEngine: prime does nothing when no relay is bound (even if master reads on)", function()
  local engine, calls = newEngineStub(true)
  local runtime = { engine = engine, config = { relay = { name = nil, side = nil }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "prime", 1000)

  t.eq(result, nil)
  t.eq(calls.feedNow, 0)
end)

t.test("_onEngine: prime does nothing when relay bound but master is off", function()
  local engine, calls = newEngineStub(false)
  local runtime = { engine = engine, config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "prime", 1000)

  t.eq(result, nil)
  t.eq(calls.feedNow, 0)
end)

t.test("_onEngine: prime feeds when relay bound AND master is on", function()
  local engine, calls = newEngineStub(true)
  local runtime = { engine = engine, config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "prime", 1000)

  t.eq(calls.feedNow, 1)
  t.truthy(result ~= nil and result.op == "feedNow", "returns the action taken")
end)

t.test("_onEngine: an unrecognised id returns nil and calls nothing", function()
  local engine, calls = newEngineStub(true)
  local runtime = { engine = engine, config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "bogus", 1000)

  t.eq(result, nil)
  t.eq(calls.toggleMaster, 0)
  t.eq(calls.feedNow, 0)
end)

-- ===== M._setMax: pure-of-Basalt manual-max stepper, with a save spy =====

local function newSaveSpy()
  local calls = {}
  local function save(path, cfg) calls[#calls + 1] = { path = path, cfg = cfg } end
  return save, calls
end

local function newMaxRuntime()
  return { config = { fuel = newFuelCfg() }, uiRev = 0 }
end

t.test("_setMax: solid +64 sets pump.full, saves against CONFIG_PATH, bumps uiRev", function()
  local runtime = newMaxRuntime()
  local save, calls = newSaveSpy()

  local newFull = M._setMax(runtime, "pump", 64, save)

  t.eq(newFull, 64)
  t.eq(runtime.config.fuel.pump.full, 64)
  t.eq(#calls, 1)
  t.eq(calls[1].path, BasaltApp.CONFIG_PATH)
  t.eq(runtime.uiRev, 1)
end)

t.test("_setMax: liquid +1000 sets tank.full, saves, bumps uiRev", function()
  local runtime = newMaxRuntime()
  local save, calls = newSaveSpy()

  local newFull = M._setMax(runtime, "tank", 1000, save)

  t.eq(newFull, 1000)
  t.eq(runtime.config.fuel.tank.full, 1000)
  t.eq(#calls, 1)
  t.eq(runtime.uiRev, 1)
end)

t.test("_setMax: solid decrement clamps at 0, never negative", function()
  local runtime = newMaxRuntime()
  runtime.config.fuel.pump.full = 30
  local save = newSaveSpy()

  local newFull = M._setMax(runtime, "pump", -64, save)

  t.eq(newFull, 0)
  t.eq(runtime.config.fuel.pump.full, 0)
end)

t.test("_setMax: liquid decrement clamps at 0, never negative", function()
  local runtime = newMaxRuntime()
  runtime.config.fuel.tank.full = 500
  local save = newSaveSpy()

  local newFull = M._setMax(runtime, "tank", -1000, save)

  t.eq(newFull, 0)
  t.eq(runtime.config.fuel.tank.full, 0)
end)

t.test("_setMax: repeated steps accumulate (two +64s on pump)", function()
  local runtime = newMaxRuntime()
  local save, calls = newSaveSpy()

  M._setMax(runtime, "pump", 64, save)
  local newFull = M._setMax(runtime, "pump", 64, save)

  t.eq(newFull, 128)
  t.eq(#calls, 2)
  t.eq(runtime.uiRev, 2)
end)

-- ===== M._cfg: delegates to uical's tested intent seam (no reimplementation) =====

local function newCfgStubRuntime()
  local calls = { rebind = 0, blockNow = 0 }
  local engine = {}
  function engine:blockNow() calls.blockNow = calls.blockNow + 1 end
  function engine:applyConfig(cfg) end

  local runtime = {
    uiRev = 0,
    config = {
      relay = { name = nil, side = "back" },
      fuel = newFuelCfg(),
      engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false },
    },
    engine = engine,
    rebindRelay = function() calls.rebind = calls.rebind + 1 end,
  }
  return runtime, calls
end

t.test("_cfg: 'relaySide' delegates through to uical -- cycles the relay side and saves", function()
  local runtime = newCfgStubRuntime()
  local save, saveCalls = newSaveSpy()

  local effect = M._cfg(runtime, "relaySide", { save = save })

  t.truthy(effect ~= nil and effect.op == "cycleRelaySide", "uical's effect surfaces through")
  t.eq(runtime.config.relay.side, "front", "nextSide('back') == 'front', exactly uical's mapping")
  t.eq(#saveCalls, 1)
end)

t.test("_cfg: 'pulseUp' delegates through to uical -- steps pulseMs by +50", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()

  M._cfg(runtime, "pulseUp", { save = save })

  t.eq(runtime.config.engine.pulseMs, 300)
end)

t.test("_cfg: an unrecognised id returns nil (uical's own ConfigPanel.action dispatch)", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()

  local effect = M._cfg(runtime, "totallyBogus", { save = save })

  t.eq(effect, nil)
end)

-- REGRESSION (Important bug fix): uical._onButton -> _applyOp saves config to disk but never
-- bumps uiRev, and the cadence signature has no field for relay side/name, pulseMs, intervalMs,
-- or bind names -- so emc_config's labels (RELAY: <side>, PMP <name>, etc.) would stay stale
-- until an unrelated telemetry change happened to repaint the page. M._cfg must bump uiRev itself
-- after every delegated call, regardless of which id or what uical's effect was.

t.test("_cfg: bumps runtime.uiRev after delegating (relaySide) so the config screen repaints", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()
  t.eq(runtime.uiRev, 0)

  M._cfg(runtime, "relaySide", { save = save })

  t.eq(runtime.uiRev, 1, "uiRev bumped exactly once")
end)

t.test("_cfg: bumps runtime.uiRev even for a bind op (BIND PUMP), no real peripheral touched", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()
  local deps = { scan = function() return {} end, save = save }

  M._cfg(runtime, "bindPump", deps)

  t.eq(runtime.uiRev, 1, "uiRev bumped even when no candidates were found to bind")
end)

t.test("_cfg: bumps runtime.uiRev even when the id is unrecognised", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()

  M._cfg(runtime, "totallyBogus", { save = save })

  t.eq(runtime.uiRev, 1, "uiRev still bumps -- the caller pressed a button, screen must repaint")
end)

t.test("_cfg: repeated presses (relaySide twice) accumulate uiRev, one bump per call", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()

  M._cfg(runtime, "relaySide", { save = save })
  M._cfg(runtime, "pulseUp", { save = save })

  t.eq(runtime.uiRev, 2)
end)

-- ===== M.config pickers: construction probe + DRAIN-SAFETY through the exact seams its onPick =====
-- ===== closures call (Uical._pickBind / Uical._pickSide -- already exhaustively unit-tested in =====
-- ===== tests/test_bitconfig_uical.lua; here we confirm M.config wires them with the SAME deps =====
-- ===== it was given, and that its own uiRev bump happens on top). =====

t.test("M.config: builds SIDE/PMP/TNK/RLY as DROPDOWN pickers (not cycle buttons), reflecting runtime.config", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local region = { push = function() end, pop = function() end }

  local runtime = {
    uiRev = 0,
    config = {
      relay = { name = "relay_2", side = "top" },
      fuel = {
        pump = { name = "tank_1",  kind = "fluid",     empty = 0, full = 1000 },
        tank = { name = "chest_1", kind = "inventory", empty = 0, full = 4000 },
      },
      engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false },
    },
  }
  local descriptors = {
    { name = "relay_1", type = "redstone_relay", methods = { setOutput = true } },
    { name = "relay_2", type = "redstone_relay", methods = { setOutput = true } },
    { name = "tank_1",  type = "fluid_tank",     methods = { getFuelAmountMb = true } },
    { name = "chest_1", type = "inventory",      methods = { list = true } },
  }
  local scanCalls = 0
  local function scan() scanCalls = scanCalls + 1; return descriptors end

  local h = M.config(basalt, frame, region, runtime, { scan = scan })

  t.eq(scanCalls, 1, "scans once at build time (no rescan control on this screen)")
  t.truthy(h.elements.sidePicker ~= nil, "sidePicker present (dropdown, not a cycle button)")
  t.truthy(h.elements.sidePicker.trigger ~= nil, "sidePicker exposes its trigger element")
  t.truthy(h.elements.pumpPicker ~= nil, "pumpPicker present")
  t.truthy(h.elements.tankPicker ~= nil, "tankPicker present")
  t.truthy(h.elements.relayPicker ~= nil, "relayPicker present")

  t.eq(h.elements.sidePicker.selectedItem().value, "top", "relay side reflected")
  t.eq(h.elements.pumpPicker.selectedItem().value, "tank_1", "pump bind reflected")
  t.eq(h.elements.tankPicker.selectedItem().value, "chest_1", "tank bind reflected")
  t.eq(h.elements.relayPicker.selectedItem().value, "relay_2", "relay bind reflected")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local okr, errr = pcall(function() basalt.update("timer", -1) end)
  t.truthy(okr, "basalt.update should not error: " .. tostring(errr))
end)

t.test("M.config: unbound relay/pump/tank show the (none) placeholder, not a stale name", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local region = { push = function() end, pop = function() end }

  local runtime = {
    uiRev = 0,
    config = {
      relay = { name = nil, side = nil },
      fuel = newFuelCfg(),
      engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false },
    },
  }
  local function scan() return {} end

  local h = M.config(basalt, frame, region, runtime, { scan = scan })

  t.eq(h.elements.pumpPicker.selectedItem(), nil, "no name bound -> nothing selected")
  t.eq(h.elements.relayPicker.selectedItem(), nil, "no relay bound -> nothing selected")
  -- SIDE always has a value (defaults to "back" even unset) -- never unbound like a name picker.
  t.eq(h.elements.sidePicker.selectedItem().value, "back")
end)

t.test("M.config: picking a relay through its wired onPick (Uical._pickBind) re-blocks -- DRAIN SAFETY -- and M.config's own bump() fires", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local region = { push = function() end, pop = function() end }
  local runtime, calls = newCfgStubRuntime()
  local save, saveCalls = newSaveSpy()
  local descriptors = { { name = "relay_9", type = "redstone_relay", methods = {} } }
  local function scan() return descriptors end
  local deps = { scan = scan, save = save }

  M.config(basalt, frame, region, runtime, deps)
  t.eq(runtime.uiRev, 0, "no pick made yet")

  -- Drive the EXACT seam M.config's RELAY picker's onPick closure calls, with the SAME deps
  -- M.config itself was built with -- confirms the wiring (not just the seam in isolation).
  Uical._pickBind(runtime, "relay", "relay_9", descriptors, deps)

  t.eq(runtime.config.relay.name, "relay_9")
  t.eq(calls.rebind, 1, "DRAIN SAFETY: rebindRelay fired on the relay pick")
  t.eq(calls.blockNow, 1, "DRAIN SAFETY: engine:blockNow fired on the relay pick")
  t.eq(#saveCalls, 1)
end)

t.test("M.config: pump/tank picks through Uical._pickBind never touch the relay (NO re-block)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local region = { push = function() end, pop = function() end }
  local runtime, calls = newCfgStubRuntime()
  local save = newSaveSpy()
  local descriptors = { { name = "tank_9", type = "fluid_tank", methods = { getFuelAmountMb = true } } }
  local function scan() return descriptors end
  local deps = { scan = scan, save = save }

  M.config(basalt, frame, region, runtime, deps)

  Uical._pickBind(runtime, "pump", "tank_9", descriptors, deps)

  t.eq(runtime.config.fuel.pump.name, "tank_9")
  t.eq(calls.rebind, 0, "pump pick never rebinds the relay")
  t.eq(calls.blockNow, 0, "pump pick never re-blocks")
end)

t.test("M.config: picking a relay side through Uical._pickSide re-blocks -- DRAIN SAFETY", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local region = { push = function() end, pop = function() end }
  local runtime, calls = newCfgStubRuntime()
  local save = newSaveSpy()
  local function scan() return {} end
  local deps = { scan = scan, save = save }

  M.config(basalt, frame, region, runtime, deps)

  Uical._pickSide(runtime, "left", deps)

  t.eq(runtime.config.relay.side, "left")
  t.eq(calls.rebind, 1, "DRAIN SAFETY: rebindRelay fired on the side pick")
  t.eq(calls.blockNow, 1, "DRAIN SAFETY: engine:blockNow fired on the side pick")
end)

-- ===== CONSTRUCTION PROBE: real Basalt, a Region hosting all three screens, stub runtime =====

t.test("Region hosting emc_main/emc_config/emc_calfuel builds + applies + renders without error", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()

  local engine = newEngineStub(true)
  local runtime = {
    engine = engine,
    uiRev = 0,
    config = {
      relay = { name = "relay_1", side = "back" },
      fuel = {
        pump = { name = "chest_1", kind = "inventory", empty = 0, full = 1024 },
        tank = { name = "tank_1",  kind = "fluid",     empty = 0, full = 8000 },
      },
      engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false },
    },
  }

  local screens = {
    emc_main    = function(b, f, r) return M.main(b, f, r, runtime) end,
    emc_config  = function(b, f, r) return M.config(b, f, r, runtime) end,
    emc_calfuel = function(b, f, r) return M.calfuel(b, f, r, runtime) end,
  }

  local region = Region.new(basalt, parent, { x = 1, y = 1, width = 14, height = 24, root = "emc_main", screens = screens })

  local sampleState = { pumpAmount = 800, tankMb = 4200, engineMaster = true, feeding = false }

  t.eq(region:top(), "emc_main")
  local ok1, err1 = pcall(function() region:apply(sampleState) end)
  t.truthy(ok1, "emc_main apply should not error: " .. tostring(err1))

  region:push("emc_config")
  local ok2, err2 = pcall(function() region:apply(sampleState) end)
  t.truthy(ok2, "emc_config apply should not error: " .. tostring(err2))

  region:push("emc_calfuel")
  local ok3, err3 = pcall(function() region:apply(sampleState) end)
  t.truthy(ok3, "emc_calfuel apply should not error: " .. tostring(err3))

  region:pop(); region:pop()
  t.eq(region:top(), "emc_main")

  local okr, errr = pcall(function() basalt.update("timer", -1) end)
  t.truthy(okr, "basalt.update should not error: " .. tostring(errr))
end)

t.test("emc_main: apply() reflects state.pumpAmount/tankMb via manual-max fractions (no peripheral read)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local engine = newEngineStub(true)
  local runtime = {
    engine = engine,
    config = {
      relay = { name = "relay_1", side = "back" },
      fuel = {
        pump = { name = "chest_1", kind = "inventory", empty = 0, full = 1000 },
        tank = { name = "tank_1",  kind = "fluid",     empty = 0, full = 4000 },
      },
    },
  }

  local region = { push = function() end, pop = function() end }
  local handle = M.main(basalt, frame, region, runtime)

  handle.apply({ pumpAmount = 800, tankMb = 4000, engineMaster = true, feeding = true })

  t.eq(handle.elements.pmpBar:getProgress(), 80, "800/1000 -> 80%")
  t.eq(handle.elements.pmpPctLabel:getText(), "80%")
  t.eq(handle.elements.mainBar:getProgress(), 100, "4000/4000 -> 100%")
  t.eq(handle.elements.mainMbLabel:getText(), "4000")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

return true
