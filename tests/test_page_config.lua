-- tests/test_page_config.lua
-- CONFIG cockpit page (ui/basalt/pages/config.lua): tests M.nextAssign (pure), the TESTABLE
-- M._onButton intent seam with a stub runtime + injected saveFn (no Basalt, no peripherals, no
-- real fs write), plus a real-CraftOS-PC Basalt construction probe -- build the element tree on a
-- frame bound to term.current(), call apply() with a stub runtime, then one basalt.update(...)
-- render pass. NEVER basalt.run() (blocks on pullEventRaw).
local t = require("tests.framework")
local M = require("ui.basalt.pages.config")
local BasaltApp = require("ui.basalt.app")

-- ===== M.nextAssign: pure cycle, mirrors ui/main.lua's nextAssign =====

t.test("nextAssign: nil -> first entry (emc)", function()
  t.eq(M.nextAssign(nil), "emc")
end)

t.test("nextAssign: emc -> fcs", function()
  t.eq(M.nextAssign("emc"), "fcs")
end)

t.test("nextAssign: last entry (ap) -> nil (wrap past the end, unassigned)", function()
  t.eq(M.ASSIGN_CYCLE[#M.ASSIGN_CYCLE], "ap")
  t.eq(M.nextAssign("ap"), nil)
end)

t.test("nextAssign: unrecognised current value -> falls back to the first entry", function()
  t.eq(M.nextAssign("bogus"), "emc")
end)

-- ===== M._onButton: assign-cycle intent dispatch, with an injected saveFn =====

local function newRuntime()
  return { config = { assign = {} }, uiRev = 0 }
end

local function newSaveSpy()
  local calls = {}
  local function saveFn(path, cfg) calls[#calls + 1] = { path = path, cfg = cfg } end
  return saveFn, calls
end

t.test("_onButton: assign:monA cycles nil -> emc, calls saveFn, bumps uiRev", function()
  local runtime = newRuntime()
  local saveFn, calls = newSaveSpy()

  local effect = M._onButton(runtime, "assign:monA", 1000, saveFn)

  t.eq(runtime.config.assign.monA, "emc")
  t.eq(#calls, 1)
  t.eq(calls[1].path, BasaltApp.CONFIG_PATH)
  t.eq(calls[1].cfg, runtime.config)
  t.eq(runtime.uiRev, 1)
  t.truthy(effect ~= nil, "effect should be returned")
  t.eq(effect.kind, "config")
  t.eq(effect.op, "cycleAssign")
  t.eq(effect.monitor, "monA")
  t.eq(effect.assigned, "emc")
end)

t.test("_onButton: clicking assign:monA again cycles emc -> fcs", function()
  local runtime = newRuntime()
  runtime.config.assign.monA = "emc"
  local saveFn, calls = newSaveSpy()

  local effect = M._onButton(runtime, "assign:monA", 2000, saveFn)

  t.eq(runtime.config.assign.monA, "fcs")
  t.eq(#calls, 1)
  t.eq(runtime.uiRev, 1)
  t.eq(effect.assigned, "fcs")
end)

t.test("_onButton: assigning one monitor does not disturb another monitor's assignment", function()
  local runtime = newRuntime()
  runtime.config.assign.monA = "emc"
  runtime.config.assign.monB = "fcs"
  local saveFn = newSaveSpy()

  M._onButton(runtime, "assign:monA", 3000, saveFn)

  t.eq(runtime.config.assign.monA, "fcs")
  t.eq(runtime.config.assign.monB, "fcs")   -- untouched
end)

t.test("_onButton: a non-assign id is ignored (nil effect, no save, uiRev untouched)", function()
  local runtime = newRuntime()
  local saveFn, calls = newSaveSpy()

  local effect = M._onButton(runtime, "somethingElse", 4000, saveFn)

  t.eq(effect, nil)
  t.eq(#calls, 0)
  t.eq(runtime.uiRev, 0)
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

t.test("M.build constructs the element tree; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()   -- binds to term.current(), per ui/basalt/app.lua's header

  local Config = require("ui.config")
  local cfg = Config.withDefaults({
    assign = { monitor_0 = "emc", monitor_1 = "fcs" },
    relay  = { name = "redstone_relay_0", side = "back" },
    fuel   = {
      pump = { name = "pump_0", kind = "inventory", empty = 0, full = 100 },
      tank = { name = "tank_0", kind = "fluid", empty = 0, full = 1000 },
    },
    engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true },
  })
  local runtime = { config = cfg, monitors = { "monitor_0", "monitor_1" }, uiRev = 0 }

  local h = M.build(basalt, frame, runtime)
  t.eq(h.id, "config")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.monButtons.monitor_0 ~= nil, "monitor_0 assign button present")
  t.truthy(h.elements.monButtons.monitor_1 ~= nil, "monitor_1 assign button present")
  t.truthy(h.elements.relayLabel ~= nil, "relayLabel present")
  t.truthy(h.elements.pumpLabel ~= nil, "pumpLabel present")
  t.truthy(h.elements.tankLabel ~= nil, "tankLabel present")
  t.truthy(h.elements.timingLabel ~= nil, "timingLabel present")

  local ok, err = pcall(h.apply, { uiRev = 1 })
  t.truthy(ok, "apply should not error: " .. tostring(err))

  -- Idempotent: calling apply() again must not error either.
  local ok2, err2 = pcall(h.apply, { uiRev = 1 })
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  t.eq(h.elements.monButtons.monitor_0:getText(), "monitor_0: emc")
  t.eq(h.elements.monButtons.monitor_1:getText(), "monitor_1: fcs")
  t.truthy(h.elements.relayLabel:getText():find("redstone_relay_0") ~= nil, "relay label shows bound name")
  t.truthy(h.elements.pumpLabel:getText():find("pump_0") ~= nil, "pump label shows bound name")
  t.truthy(h.elements.tankLabel:getText():find("tank_0") ~= nil, "tank label shows bound name")
  t.truthy(h.elements.timingLabel:getText():find("250") ~= nil, "timing label shows pulseMs")

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build's monitor button click cycles the assignment through _onButton + apply() reflects it", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local Config = require("ui.config")
  local cfg = Config.withDefaults({ assign = {} })
  local runtime = { config = cfg, monitors = { "monitor_0" }, uiRev = 0 }

  local h = M.build(basalt, frame, runtime)
  local ok, err = pcall(h.apply, { uiRev = 0 })
  t.truthy(ok, "initial apply should not error: " .. tostring(err))
  t.eq(h.elements.monButtons.monitor_0:getText(), "monitor_0: --")

  -- Directly invoke the same intent seam the button's onClick wires up (a real click through
  -- Basalt's event loop needs basalt.run(), which blocks -- forbidden here; see header comment).
  local saveFn = function() end
  M._onButton(runtime, "assign:monitor_0", os.epoch("utc"), saveFn)
  t.eq(runtime.config.assign.monitor_0, "emc")

  local ok2, err2 = pcall(h.apply, { uiRev = runtime.uiRev })
  t.truthy(ok2, "apply after assignment change should not error: " .. tostring(err2))
  t.eq(h.elements.monButtons.monitor_0:getText(), "monitor_0: emc")
end)

return true
