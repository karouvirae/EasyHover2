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
  t.truthy(h.elements.monPickers.monitor_0 ~= nil, "monitor_0 assign picker present")
  t.truthy(h.elements.monPickers.monitor_1 ~= nil, "monitor_1 assign picker present")
  t.truthy(h.elements.relayLabel ~= nil, "relayLabel present")
  t.truthy(h.elements.pumpLabel ~= nil, "pumpLabel present")
  t.truthy(h.elements.tankLabel ~= nil, "tankLabel present")
  t.truthy(h.elements.timingLabel ~= nil, "timingLabel present")

  local ok, err = pcall(h.apply, { uiRev = 1 })
  t.truthy(ok, "apply should not error: " .. tostring(err))

  -- Idempotent: calling apply() again must not error either.
  local ok2, err2 = pcall(h.apply, { uiRev = 1 })
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  t.eq(h.elements.monPickers.monitor_0.dropdown:getSelectedItem().value, "emc", "picker reflects monitor_0 assignment")
  t.eq(h.elements.monPickers.monitor_1.dropdown:getSelectedItem().value, "fcs", "picker reflects monitor_1 assignment")
  t.truthy(h.elements.relayLabel:getText():find("redstone_relay_0") ~= nil, "relay label shows bound name")
  t.truthy(h.elements.pumpLabel:getText():find("pump_0") ~= nil, "pump label shows bound name")
  t.truthy(h.elements.tankLabel:getText():find("tank_0") ~= nil, "tank label shows bound name")
  t.truthy(h.elements.timingLabel:getText():find("250") ~= nil, "timing label shows pulseMs")

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("_assignOptions lists (none) + every monitor-displayable page", function()
  local opts = M._assignOptions()
  t.eq(opts[1].value, false); t.eq(opts[1].text, "(none)")
  -- the rest mirror ASSIGN_CYCLE in order
  for i, id in ipairs(M.ASSIGN_CYCLE) do t.eq(opts[i + 1].value, id) end
end)

t.test("_pickAssign sets the chosen page directly (not a cycle), saves, bumps uiRev", function()
  local saved = {}
  local saveFn = function(path, cfg) saved.path = path; saved.cfg = cfg end
  local runtime = { config = { assign = {} }, uiRev = 0 }
  M._pickAssign(runtime, "monitor_0", "flight", saveFn)
  t.eq(runtime.config.assign.monitor_0, "flight", "picked page set directly")
  t.eq(runtime.uiRev, 1, "uiRev bumped -> render-gate repaints")
  t.truthy(saved.cfg == runtime.config, "persisted the config")
  M._pickAssign(runtime, "monitor_0", false, saveFn)
  t.eq(runtime.config.assign.monitor_0, nil, "(none) unassigns the monitor")
end)

t.test("M.build's assignment picker reflects a _pickAssign change after apply()", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local Config = require("ui.config")
  local runtime = { config = Config.withDefaults({ assign = {} }), monitors = { "monitor_0" }, uiRev = 0 }

  local h = M.build(basalt, frame, runtime)
  h.apply({ uiRev = 0 })
  t.eq(h.elements.monPickers.monitor_0.dropdown:getSelectedItem().value, false, "unassigned -> (none) selected")

  M._pickAssign(runtime, "monitor_0", "flight", function() end)  -- same seam the picker's onPick calls
  h.apply({ uiRev = runtime.uiRev })
  t.eq(h.elements.monPickers.monitor_0.dropdown:getSelectedItem().value, "flight", "picker follows the new assignment")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

return true
