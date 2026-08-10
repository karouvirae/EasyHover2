-- tests/test_page_emc.lua
-- EMC cockpit page (ui/basalt/pages/emc.lua): tests the TESTABLE M._onButton intent seam with a
-- stub runtime (no Basalt, no peripherals), plus a real-CraftOS-PC Basalt construction probe --
-- build the element tree on a frame bound to term.current(), call apply() with a full canonical
-- state, then one basalt.update(...) render pass. NEVER basalt.run() (blocks on pullEventRaw).
local t = require("tests.framework")
local M = require("ui.basalt.pages.emc")
local BasaltApp = require("ui.basalt.app")

-- ===== stub runtime: engine stub records calls, no peripheral/Basalt access =====

local function newEngineStub(status)
  local calls = {}
  local stub = { calls = calls }
  function stub:status(now) return status end
  function stub:setMaster(on, now) calls[#calls + 1] = { op = "setMaster", on = on, now = now } end
  function stub:feedNow(now) calls[#calls + 1] = { op = "feedNow", now = now } end
  return stub, calls
end

local function newRuntime(bound, status)
  status = status or { master = false, feeding = false, pulses = 0, nextFeedInMs = nil }
  local engine, calls = newEngineStub(status)
  local relay = bound and { name = "relay0", side = "top" } or { name = nil, side = nil }
  return { engine = engine, config = { relay = relay } }, calls
end

-- ===== M._onButton: relay-gated intent dispatch =====

t.test("_onButton: relay unbound -> engineOn is gated, nil effect, engine untouched", function()
  local runtime, calls = newRuntime(false)
  local effect = M._onButton(runtime, "engineOn", 1000)
  t.eq(effect, nil)
  t.eq(#calls, 0, "gated: no engine method should have been called")
end)

t.test("_onButton: relay unbound -> engineOff and prime are also gated", function()
  local runtime, calls = newRuntime(false)
  t.eq(M._onButton(runtime, "engineOff", 1000), nil)
  t.eq(M._onButton(runtime, "prime", 1000), nil)
  t.eq(#calls, 0)
end)

t.test("_onButton: relay bound -> engineOn calls engine:setMaster(true, now)", function()
  local runtime, calls = newRuntime(true)
  local effect = M._onButton(runtime, "engineOn", 1000)
  t.truthy(effect ~= nil, "effect should be returned")
  t.eq(effect.kind, "engine")
  t.eq(effect.op, "on")
  t.eq(#calls, 1)
  t.eq(calls[1].op, "setMaster")
  t.eq(calls[1].on, true)
  t.eq(calls[1].now, 1000)
end)

t.test("_onButton: relay bound -> engineOff calls engine:setMaster(false, now)", function()
  local runtime, calls = newRuntime(true, { master = true, feeding = false, pulses = 1 })
  local effect = M._onButton(runtime, "engineOff", 2000)
  t.eq(effect.op, "off")
  t.eq(#calls, 1)
  t.eq(calls[1].op, "setMaster")
  t.eq(calls[1].on, false)
  t.eq(calls[1].now, 2000)
end)

t.test("_onButton: relay bound -> prime calls engine:feedNow(now)", function()
  local runtime, calls = newRuntime(true, { master = true, feeding = false, pulses = 1 })
  local effect = M._onButton(runtime, "prime", 3000)
  t.eq(effect.op, "prime")
  t.eq(#calls, 1)
  t.eq(calls[1].op, "feedNow")
  t.eq(calls[1].now, 3000)
end)

t.test("_onButton: relay bound but engine already off -> prime is gated by the panel's own rule", function()
  -- ui/panels/engine.lua's M.action gates purely on relayBound; the "prime disabled while off"
  -- rule lives only in buttonStates() (the UI affordance), so a bound-but-off prime click still
  -- dispatches an effect here -- mirrors the old panel's action() semantics exactly.
  local runtime, calls = newRuntime(true, { master = false, feeding = false, pulses = 0 })
  local effect = M._onButton(runtime, "prime", 4000)
  t.eq(effect.op, "prime")
  t.eq(calls[1].op, "feedNow")
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

t.test("M.build constructs the element tree; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()   -- binds to term.current(), per ui/basalt/app.lua's header

  local runtime = newRuntime(true, { master = true, feeding = true, pulses = 5, nextFeedInMs = 12345 })

  local h = M.build(basalt, frame, runtime)
  t.eq(h.id, "emc")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.pumpBar ~= nil, "pumpBar element present")
  t.truthy(h.elements.tankBar ~= nil, "tankBar element present")
  t.truthy(h.elements.engineOnBtn ~= nil, "engineOnBtn element present")
  t.truthy(h.elements.engineOffBtn ~= nil, "engineOffBtn element present")
  t.truthy(h.elements.primeBtn ~= nil, "primeBtn element present")

  local sampleState = {
    engineMaster = true, feeding = true, pulses = 5, nextFeedInMs = 12345,
    pumpFrac = 0.42, tankFrac = 0.9, uiRev = 1,
  }
  local ok, err = pcall(h.apply, sampleState)
  t.truthy(ok, "apply should not error: " .. tostring(err))

  -- Idempotent: calling apply() again with the same/changed state must not error either.
  local ok2, err2 = pcall(h.apply, sampleState)
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build's apply() reflects an unbound relay: buttons disabled, RELAY unbound", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local runtime = newRuntime(false, { master = false, feeding = false, pulses = 0, nextFeedInMs = nil })
  local h = M.build(basalt, frame, runtime)

  local ok, err = pcall(h.apply, {
    engineMaster = false, feeding = false, pulses = 0, nextFeedInMs = nil,
    pumpFrac = 0, tankFrac = 0, uiRev = 0,
  })
  t.truthy(ok, "apply should not error on an unbound relay: " .. tostring(err))
  t.eq(h.elements.engineOnBtn:getEnabled(), false, "engineOn disabled when relay unbound")
  t.eq(h.elements.engineOffBtn:getEnabled(), false, "engineOff disabled when relay unbound")
  t.eq(h.elements.primeBtn:getEnabled(), false, "prime disabled when relay unbound")
end)
