-- tests/test_page_ap.lua
-- A/P cockpit page (ui/basalt/pages/ap.lua): tests the TESTABLE M._onButton intent seam with a
-- stub runtime (no Basalt, no peripherals), plus a real-CraftOS-PC Basalt construction probe --
-- build the element tree on a frame bound to term.current(), call apply() with a full canonical
-- state, then one basalt.update(...) render pass. NEVER basalt.run() (blocks on pullEventRaw).
local t = require("tests.framework")
local M = require("ui.basalt.pages.ap")
local BasaltApp = require("ui.basalt.app")

-- ===== stub runtime: links.tel records :send args, sender:send is an identity pass-through,
-- rx:latest() returns a controllable table (no peripheral/Basalt access anywhere here) =====

local function newTelLink()
  local sent = {}
  local link = { sent = sent }
  function link:send(frame) sent[#sent + 1] = frame end
  return link, sent
end

local function newSender()
  return { send = function(self, cmd) return cmd end }
end

local function newRx(latest)
  return { latest = function(self) return latest end }
end

local function newRuntime(latest)
  local tel, sent = newTelLink()
  return {
    links = { tel = tel },
    sender = newSender(),
    rx = newRx(latest),
  }, sent
end

-- ===== M._onButton: gated intent dispatch, mirroring ui/main.lua's applyEffect "command" block =====

t.test("_onButton: positionHold currently off -> cmd.k==\"positionHold\", cmd.on==true", function()
  local runtime, sent = newRuntime({ positionHold = false, mode = "FLIGHT" })
  local effect = M._onButton(runtime, "positionHold", 1000)
  t.eq(effect.kind, "command")
  t.eq(effect.cmd.k, "positionHold")
  t.eq(effect.cmd.on, true)
  t.eq(#sent, 1)
  t.eq(sent[1].k, "positionHold")
  t.eq(sent[1].on, true)
end)

t.test("_onButton: positionHold currently on -> cmd.on==false (request off)", function()
  local runtime, sent = newRuntime({ positionHold = true, mode = "FLIGHT" })
  local effect = M._onButton(runtime, "positionHold", 2000)
  t.eq(effect.kind, "command")
  t.eq(effect.cmd.k, "positionHold")
  t.eq(effect.cmd.on, false)
  t.eq(#sent, 1)
  t.eq(sent[1].on, false)
end)

t.test("_onButton: clearDamped when mode==DAMPED -> cmd.k==\"clearDamped\" (active)", function()
  local runtime, sent = newRuntime({ positionHold = false, mode = "DAMPED" })
  local effect = M._onButton(runtime, "clearDamped", 3000)
  t.eq(effect.kind, "command")
  t.eq(effect.cmd.k, "clearDamped")
  t.eq(#sent, 1)
  t.eq(sent[1].k, "clearDamped")
end)

t.test("_onButton: clearDamped when mode~=DAMPED -> cmd.k==\"clearDamped\" (idle, but still sends)", function()
  local runtime, sent = newRuntime({ positionHold = false, mode = "FLIGHT" })
  local effect = M._onButton(runtime, "clearDamped", 4000)
  t.eq(effect.kind, "command")
  t.eq(effect.cmd.k, "clearDamped")
  t.eq(#sent, 1)
  t.eq(sent[1].k, "clearDamped")
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

t.test("M.build constructs the element tree; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()   -- binds to term.current(), per ui/basalt/app.lua's header

  local runtime = newRuntime({ positionHold = false, mode = "FLIGHT" })

  local h = M.build(basalt, frame, runtime)
  t.eq(h.id, "ap")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.posHoldBtn ~= nil, "posHoldBtn element present")
  t.truthy(h.elements.clrDampBtn ~= nil, "clrDampBtn element present")
  t.truthy(h.elements.altHoldBtn ~= nil, "altHoldBtn placeholder present")
  t.truthy(h.elements.waypointBtn ~= nil, "waypointBtn placeholder present")
  t.truthy(h.elements.rtbBtn ~= nil, "rtbBtn placeholder present")

  -- Placeholder A/P mode buttons are disabled visual-only affordances -- no onClick, no intent seam.
  t.eq(h.elements.altHoldBtn:getEnabled(), false, "altHold placeholder disabled")
  t.eq(h.elements.waypointBtn:getEnabled(), false, "waypoint placeholder disabled")
  t.eq(h.elements.rtbBtn:getEnabled(), false, "rtb placeholder disabled")

  local sampleState = {
    positionHold = false, mode = "FLIGHT", uiRev = 1,
  }
  local ok, err = pcall(h.apply, sampleState)
  t.truthy(ok, "apply should not error: " .. tostring(err))

  -- Idempotent: calling apply() again with the same/changed state must not error either.
  local ok2, err2 = pcall(h.apply, sampleState)
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build's apply() reflects positionHold state: on -> button green active", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local runtime = newRuntime({ positionHold = true, mode = "FLIGHT" })
  local h = M.build(basalt, frame, runtime)

  local ok, err = pcall(h.apply, {
    positionHold = true, mode = "FLIGHT", uiRev = 1,
  })
  t.truthy(ok, "apply should not error with positionHold on: " .. tostring(err))
  t.eq(h.elements.posHoldBtn:getBackground(), colors.green, "posHold green when on")
  t.eq(h.elements.posHoldBtn:getEnabled(), true, "posHold enabled when on")
end)

t.test("M.build's apply() reflects clearDamped active when mode==DAMPED", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local runtime = newRuntime({ positionHold = false, mode = "DAMPED" })
  local h = M.build(basalt, frame, runtime)

  local ok, err = pcall(h.apply, {
    positionHold = false, mode = "DAMPED", uiRev = 1,
  })
  t.truthy(ok, "apply should not error with mode==DAMPED: " .. tostring(err))
  t.eq(h.elements.clrDampBtn:getBackground(), colors.green, "clrDamp green when mode==DAMPED")
  t.eq(h.elements.clrDampBtn:getEnabled(), true, "clrDamp enabled when mode==DAMPED")
end)

t.test("M.build's apply() reflects clearDamped idle when mode~=DAMPED", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local runtime = newRuntime({ positionHold = false, mode = "FLIGHT" })
  local h = M.build(basalt, frame, runtime)

  local ok, err = pcall(h.apply, {
    positionHold = false, mode = "FLIGHT", uiRev = 1,
  })
  t.truthy(ok, "apply should not error with mode==FLIGHT: " .. tostring(err))
  t.eq(h.elements.clrDampBtn:getBackground(), colors.gray, "clrDamp gray when mode~=DAMPED")
  t.eq(h.elements.clrDampBtn:getEnabled(), true, "clrDamp enabled (idle) when mode~=DAMPED")
end)

return true
