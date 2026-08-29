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

t.test("_onButton: trimUp -> cmd.k==\"flightTrim\", cmd.dir==1", function()
  local runtime, sent = newRuntime({ engaged = true, gndSafety = false, positionHold = false, mode = "FLIGHT" })
  local effect = M._onButton(runtime, "trimUp", 4500)
  t.eq(effect.kind, "command")
  t.eq(effect.cmd.k, "flightTrim")
  t.eq(effect.cmd.dir, 1)
  t.eq(#sent, 1)
  t.eq(sent[1].k, "flightTrim")
  t.eq(sent[1].dir, 1)
end)

t.test("_onButton: trimDn -> cmd.k==\"flightTrim\", cmd.dir==-1", function()
  local runtime, sent = newRuntime({ engaged = true, gndSafety = false, positionHold = false, mode = "FLIGHT" })
  local effect = M._onButton(runtime, "trimDn", 4600)
  t.eq(effect.cmd.k, "flightTrim")
  t.eq(effect.cmd.dir, -1)
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
  t.truthy(h.elements.modeBtns.LDG ~= nil, "LDG mode switch present")
  t.truthy(h.elements.modeBtns.DRN ~= nil, "DRN mode switch present")
  t.truthy(h.elements.masterBtns ~= nil, "masterBtns table present")
  t.truthy(h.elements.masterBtns.CPL ~= nil, "CPL master switch present")
  t.truthy(h.elements.masterBtns.DCPL ~= nil, "DCPL master switch present")
  t.truthy(h.elements.trimBtn ~= nil, "trimBtn element present")

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

  -- flightMode == "MAN" is not CPL/DCPL, so the trim button reads disabled/"TRIM --".
  t.eq(h.elements.trimBtn:getEnabled(), false, "trim button disabled outside CPL/DCPL")
  t.eq(h.elements.trimBtn:getText(), "TRIM --", "trim button shows placeholder outside CPL/DCPL")

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

t.test("FIT CHECK: mode selector row fits a realistic narrow frame width (14 cols), all 5 short labels", function()
  -- config-UI-overhaul lesson: assert the fit against an EXPLICIT small/narrow frame, not the wide
  -- headless terminal term.current() binds by default (see tests/test_bitconfig_tuning.lua's
  -- "every screen must fit a REALISTIC monitor" regression, same 14x12 convention).
  local basalt = BasaltApp.ensureBasalt()
  local root = basalt.createFrame()
  local frame = root:addFrame({ x = 1, y = 1, width = 14, height = 12 })
  local frameW, frameH = frame:getSize()
  t.eq(frameW, 14, "sanity: the narrow frame really is 14 cols wide, not the wide headless default")

  local runtime = newRuntime({ engaged = false, gndSafety = false, positionHold = false, mode = "GROUND" })
  local h = M.build(basalt, frame, runtime)

  t.truthy(h.elements.masterBtns.CPL ~= nil, "CPL present on the narrow frame too")
  t.truthy(h.elements.masterBtns.DCPL ~= nil, "DCPL present on the narrow frame too")

  for id, btn in pairs(h.elements.modeBtns) do
    local ex, ew = btn:getX(), btn:getWidth()
    t.truthy(ex + ew - 1 <= frameW - 1,
      id .. " switch overshoots the interior width: x=" .. tostring(ex) .. " width=" .. tostring(ew) ..
      " frameW=" .. tostring(frameW))
  end

  for id, btn in pairs(h.elements.masterBtns) do
    local ex, ew = btn:getX(), btn:getWidth()
    t.truthy(ex + ew - 1 <= frameW - 1,
      id .. " master switch overshoots the interior width: x=" .. tostring(ex) .. " width=" .. tostring(ew) ..
      " frameW=" .. tostring(frameW))
  end
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

t.test("M.build's apply() reflects trimDir while in CPL/DCPL (gated on masterMode)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local runtime = newRuntime({ engaged = true, gndSafety = false, positionHold = false, mode = "FLIGHT" })
  local h = M.build(basalt, frame, runtime)

  -- Trim gating is on masterMode, NOT flightMode -- flightMode here is a real flight mode (MAN)
  -- while masterMode carries CPL/DCPL, mirroring the two independent exclusive groups.
  local ok, err = pcall(h.apply, {
    engaged = true, gndSafety = false, positionHold = false, mode = "FLIGHT",
    altitude = 10, vSpeed = 0, heading = 0, loopHz = 20, linkUp = true, uiRev = 1,
    flightMode = "MAN", masterMode = "CPL", trimDir = 1,
  })
  t.truthy(ok, "apply should not error with masterMode CPL: " .. tostring(err))
  t.eq(h.elements.trimBtn:getEnabled(), true, "trim button enabled in CPL")
  t.eq(h.elements.trimBtn:getText(), "TRIM UP", "trim button shows TRIM UP when trimDir==1")
  -- No-optimistic-UI master highlight: CPL is the reported masterMode, so both switches read
  -- enabled (neither is "disabled") -- mirrors the existing mode-switch assertions above, which
  -- likewise can only observe "not disabled" (on/off share enabled==true; see switchbtn.lua).
  t.eq(h.elements.masterBtns.CPL:getEnabled(), true, "CPL master switch enabled once apply() has run")
  t.eq(h.elements.masterBtns.DCPL:getEnabled(), true, "DCPL master switch enabled once apply() has run")

  local ok2, err2 = pcall(h.apply, {
    engaged = true, gndSafety = false, positionHold = false, mode = "FLIGHT",
    altitude = 10, vSpeed = 0, heading = 0, loopHz = 20, linkUp = true, uiRev = 1,
    flightMode = "MAN", masterMode = "DCPL", trimDir = -1,
  })
  t.truthy(ok2, "apply should not error with masterMode DCPL: " .. tostring(err2))
  t.eq(h.elements.trimBtn:getEnabled(), true, "trim button enabled in DCPL")
  t.eq(h.elements.trimBtn:getText(), "TRIM DN", "trim button shows TRIM DN when trimDir==-1")
end)

t.test("page/fcs: master switches present and driven by masterMode", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local runtime = newRuntime({ engaged = false, gndSafety = false, positionHold = false, mode = "GROUND" })
  local h = M.build(basalt, frame, runtime)

  t.truthy(h.elements.masterBtns.CPL ~= nil, "CPL master switch present")
  t.truthy(h.elements.masterBtns.DCPL ~= nil, "DCPL master switch present")

  local ok, err = pcall(h.apply, {
    engaged = false, gndSafety = false, positionHold = false, mode = "GROUND",
    altitude = 0, vSpeed = 0, heading = 0, loopHz = 0, linkUp = false, uiRev = 0,
    flightMode = "MAN", masterMode = "DCPL",
  })
  t.truthy(ok, "apply should not error with masterMode DCPL: " .. tostring(err))
  t.eq(h.elements.masterBtns.DCPL:getEnabled(), true, "DCPL switch enabled once apply() has run")
  t.eq(h.elements.masterBtns.CPL:getEnabled(), true, "CPL switch enabled once apply() has run")

  local ok2, err2 = pcall(h.apply, {
    engaged = false, gndSafety = false, positionHold = false, mode = "GROUND",
    altitude = 0, vSpeed = 0, heading = 0, loopHz = 0, linkUp = false, uiRev = 0,
    flightMode = "MAN", masterMode = "CPL",
  })
  t.truthy(ok2, "apply should not error with masterMode CPL: " .. tostring(err2))
  t.eq(h.elements.masterBtns.CPL:getEnabled(), true, "CPL switch enabled once apply() has run")
end)

return true
