-- tests/test_page_fcs.lua
-- FCS cockpit page (ui/basalt/pages/fcs.lua): tests the TESTABLE M._onButton intent seam with a
-- stub runtime (no Basalt, no peripherals), plus a real-CraftOS-PC Basalt construction probe --
-- build the element tree on a frame bound to term.current(), call apply() with a full canonical
-- state, then one basalt.update(...) render pass. NEVER basalt.run() (blocks on pullEventRaw).
local t = require("tests.framework")
local M = require("ui.basalt.pages.fcs")
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

t.test("_onButton: engage while gndSafety on -> nil effect, nothing sent", function()
  local runtime, sent = newRuntime({ engaged = false, gndSafety = true, positionHold = false, mode = "GROUND" })
  local effect = M._onButton(runtime, "engage", 1000)
  t.eq(effect, nil)
  t.eq(#sent, 0, "gated: no frame should have been sent")
end)

t.test("_onButton: engage while gndSafety off -> a frame carrying cmd.k==\"engage\" was sent", function()
  local runtime, sent = newRuntime({ engaged = false, gndSafety = false, positionHold = false, mode = "GROUND" })
  local effect = M._onButton(runtime, "engage", 1000)
  t.truthy(effect ~= nil, "effect should be returned")
  t.eq(effect.kind, "command")
  t.eq(effect.cmd.k, "engage")
  t.eq(#sent, 1)
  t.eq(sent[1].k, "engage")
end)

t.test("_onButton: disengage -> cmd.k==\"disengage\"", function()
  local runtime, sent = newRuntime({ engaged = true, gndSafety = false, positionHold = false, mode = "FLIGHT" })
  local effect = M._onButton(runtime, "disengage", 2000)
  t.eq(effect.cmd.k, "disengage")
  t.eq(#sent, 1)
  t.eq(sent[1].k, "disengage")
end)

t.test("_onButton: gndSafety currently off -> cmd.k==\"gndSafety\", cmd.on==true", function()
  local runtime, sent = newRuntime({ engaged = false, gndSafety = false, positionHold = false, mode = "GROUND" })
  local effect = M._onButton(runtime, "gndSafety", 3000)
  t.eq(effect.cmd.k, "gndSafety")
  t.eq(effect.cmd.on, true)
  t.eq(#sent, 1)
  t.eq(sent[1].on, true)
end)

t.test("_onButton: gndSafety currently on -> cmd.on==false (request off)", function()
  local runtime, sent = newRuntime({ engaged = false, gndSafety = true, positionHold = false, mode = "GROUND" })
  local effect = M._onButton(runtime, "gndSafety", 4000)
  t.eq(effect.cmd.k, "gndSafety")
  t.eq(effect.cmd.on, false)
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

t.test("M.build constructs the element tree; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()   -- binds to term.current(), per ui/basalt/app.lua's header

  local runtime = newRuntime({ engaged = false, gndSafety = false, positionHold = false, mode = "GROUND" })

  local h = M.build(basalt, frame, runtime)
  t.eq(h.id, "fcs")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.engageBtn ~= nil, "engageBtn element present")
  t.truthy(h.elements.disengageBtn ~= nil, "disengageBtn element present")
  t.truthy(h.elements.gndSafetyBtn ~= nil, "gndSafetyBtn element present")
  t.truthy(h.elements.modeBtns ~= nil, "modeBtns table present")
  t.truthy(h.elements.modeBtns.PRECISION ~= nil, "PRECISION mode switch present")
  t.truthy(h.elements.modeBtns.MAN ~= nil, "MAN mode switch present")
  t.truthy(h.elements.modeBtns.CRUISE ~= nil, "CRUISE mode switch present")

  local sampleState = {
    engaged = true, gndSafety = false, positionHold = false, mode = "FLIGHT",
    altitude = 42.5, vSpeed = -0.3, heading = 180, loopHz = 20, linkUp = true, uiRev = 1,
    flightMode = "MAN",
  }
  local ok, err = pcall(h.apply, sampleState)
  t.truthy(ok, "apply should not error: " .. tostring(err))

  -- No-optimistic-UI: apply() drives the mode switches purely from reported state.flightMode --
  -- only the reported mode is enabled/"on" (green), the others are "off" (red).
  t.eq(h.elements.modeBtns.MAN:getEnabled(), true, "MAN switch enabled once apply() has run")
  t.eq(h.elements.modeBtns.PRECISION:getEnabled(), true, "PRECISION switch enabled once apply() has run")

  -- Idempotent: calling apply() again with the same/changed state must not error either.
  local ok2, err2 = pcall(h.apply, sampleState)
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("_onButton: mode id sends the raw flightMode command through the same command path", function()
  local runtime, sent = newRuntime({ engaged = true, gndSafety = false, positionHold = false, mode = "FLIGHT" })
  local effect = M._onButton(runtime, "CRUISE", 5000)
  t.truthy(effect ~= nil, "effect should be returned")
  t.eq(effect.k, "flightMode")
  t.eq(effect.id, "CRUISE")
  t.eq(#sent, 1, "one frame sent through runtime.links.tel, same as ENGAGE/DISENGAGE")
  t.eq(sent[1].k, "flightMode")
  t.eq(sent[1].id, "CRUISE")
end)

t.test("M.build's apply() reflects gndSafety-on: engage disabled", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local runtime = newRuntime({ engaged = false, gndSafety = true, positionHold = false, mode = "GROUND" })
  local h = M.build(basalt, frame, runtime)

  local ok, err = pcall(h.apply, {
    engaged = false, gndSafety = true, positionHold = false, mode = "GROUND",
    altitude = 0, vSpeed = 0, heading = 0, loopHz = 0, linkUp = false, uiRev = 0,
  })
  t.truthy(ok, "apply should not error with gndSafety on: " .. tostring(err))
  t.eq(h.elements.engageBtn:getEnabled(), false, "engage disabled when gndSafety on")
end)

return true
