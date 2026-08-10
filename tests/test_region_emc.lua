-- tests/test_region_emc.lua
-- EMC region screens (ui/basalt/regions/emc.lua) for the merged "flight" cockpit page.
-- Covers the three Basalt-free intent seams (M._onEngine / M._cfg / M._setMax) with stub
-- runtimes, then a CONSTRUCTION PROBE: a real ui/basalt/region.lua Region hosting all three
-- screens, apply() on each, one basalt.update("timer",-1) render pass. NEVER basalt.run().
local t = require("tests.framework")
local M = require("ui.basalt.regions.emc")
local Region = require("ui.basalt.region")
local BasaltApp = require("ui.basalt.app")

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
