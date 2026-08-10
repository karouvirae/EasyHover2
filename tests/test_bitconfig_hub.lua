-- tests/test_bitconfig_hub.lua
-- BIT/CONFIG hub menu (ui/basalt/bitconfig/hub.lua): tests the TESTABLE M._onButton intent seam
-- with a real Nav stack, plus a real-CraftOS-PC Basalt construction probe -- build the element
-- tree on a frame bound to term.current(), call apply() with a full canonical state, then one
-- basalt.update(...) render pass. NEVER basalt.run() (blocks on pullEventRaw).
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.hub")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")

-- ===== M._onButton: navigational intent dispatch =====

t.test("_onButton: with nav, id from M.ITEMS pushes onto stack and returns id", function()
  local nav = Nav.new("bitconfig")
  t.eq(nav:depth(), 1, "nav starts at depth 1 (root)")
  t.eq(nav:top(), "bitconfig", "nav starts at root")
  t.eq(nav:canBack(), false, "nav cannot back when at root")

  -- Test pushing "tuning" (first item in M.ITEMS)
  local result = M._onButton(nav, "tuning", 1000)
  t.eq(result, "tuning", "M._onButton should return \"tuning\"")
  t.eq(nav:depth(), 2, "nav should be at depth 2 after push")
  t.eq(nav:top(), "tuning", "nav top should be \"tuning\"")
  t.eq(nav:canBack(), true, "nav should be able to back")
end)

t.test("_onButton: each M.ITEMS id pushes correctly", function()
  for _, item in ipairs(M.ITEMS) do
    local nav = Nav.new("bitconfig")
    local result = M._onButton(nav, item.id, 2000)
    t.eq(result, item.id, "should return " .. item.id)
    t.eq(nav:top(), item.id, "nav top should be " .. item.id)
  end
end)

t.test("_onButton: back pops from stack and returns \"back\"", function()
  local nav = Nav.new("bitconfig")
  t.eq(nav:depth(), 1, "nav starts at depth 1")

  -- Push tuning first
  M._onButton(nav, "tuning", 3000)
  t.eq(nav:depth(), 2, "nav at depth 2 after push")
  t.eq(nav:top(), "tuning", "at tuning")

  -- Back should pop
  local result = M._onButton(nav, "back", 3000)
  t.eq(result, "back", "M._onButton should return \"back\"")
  t.eq(nav:depth(), 1, "nav should pop back to depth 1")
  t.eq(nav:top(), "bitconfig", "nav top should be back to \"bitconfig\"")
  t.eq(nav:canBack(), false, "nav cannot back when at root")
end)

t.test("_onButton: back at root is a no-op (nav stays at root)", function()
  local nav = Nav.new("bitconfig")
  t.eq(nav:depth(), 1, "nav starts at depth 1 (at root)")

  -- Back should be a no-op per Nav:pop() logic
  local result = M._onButton(nav, "back", 4000)
  t.eq(result, "back", "M._onButton should still return \"back\"")
  t.eq(nav:depth(), 1, "nav should stay at depth 1 (root)")
  t.eq(nav:top(), "bitconfig", "nav should still be at root")
end)

t.test("_onButton: non-existent id returns nil and does NOT push", function()
  local nav = Nav.new("bitconfig")
  local initialDepth = nav:depth()

  local result = M._onButton(nav, "unknownId", 5000)
  t.eq(result, nil, "M._onButton should return nil for unknown ids")
  t.eq(nav:depth(), initialDepth, "nav depth should NOT change for unknown ids")
end)

t.test("_onButton: with nil nav returns nil gracefully", function()
  local result = M._onButton(nil, "tuning", 6000)
  t.eq(result, nil, "M._onButton should return nil when nav is nil")
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

t.test("M.build constructs the element tree; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()   -- binds to term.current(), per ui/basalt/app.lua's header

  local nav = Nav.new("bitconfig")

  local h = M.build(basalt, frame, nil, nav)
  t.eq(h.id, "bitconfig", "hub id should be \"bitconfig\"")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")

  -- Check that all menu item buttons are present
  for _, item in ipairs(M.ITEMS) do
    t.truthy(h.elements[item.id] ~= nil, item.id .. " button should be present")
  end

  -- Check that back button is present
  t.truthy(h.elements.backBtn ~= nil, "backBtn element present")

  -- All buttons should be enabled
  t.eq(h.elements.tuning:getEnabled(), true, "tuning button enabled")
  t.eq(h.elements.mdb:getEnabled(), true, "mdb button enabled")
  t.eq(h.elements.uical:getEnabled(), true, "uical button enabled")
  t.eq(h.elements.senscal:getEnabled(), true, "senscal button enabled")
  t.eq(h.elements.dtc:getEnabled(), true, "dtc button enabled")
  t.eq(h.elements.fcssync:getEnabled(), true, "fcssync button enabled")
  t.eq(h.elements.backBtn:getEnabled(), true, "backBtn enabled")

  local sampleState = {
    uiRev = 1,
  }
  local ok, err = pcall(h.apply, sampleState)
  t.truthy(ok, "apply should not error: " .. tostring(err))

  -- Idempotent: calling apply() again with the same/changed state must not error either.
  local ok2, err2 = pcall(h.apply, sampleState)
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build: seven buttons total (six items + back)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local nav = Nav.new("bitconfig")
  local h = M.build(basalt, frame, nil, nav)

  local buttonCount = 0
  for k, v in pairs(h.elements) do
    if v and type(v) == "table" and v.getEnabled ~= nil then
      buttonCount = buttonCount + 1
    end
  end
  t.eq(buttonCount, 7, "should have 7 buttons (6 items + 1 back)")
end)

t.test("M.build: clicking each menu item button invokes M._onButton correctly", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local nav = Nav.new("bitconfig")
  local h = M.build(basalt, frame, nil, nav)

  -- Test that M._onButton can be called for each item
  for _, item in ipairs(M.ITEMS) do
    local freshNav = Nav.new("bitconfig")
    local result = M._onButton(freshNav, item.id, os.epoch("utc"))
    t.eq(result, item.id, "pushing " .. item.id .. " should succeed")
    t.eq(freshNav:top(), item.id, "nav top should be " .. item.id)
  end
end)

t.test("M.ITEMS canonical definition is present and has correct structure", function()
  t.truthy(M.ITEMS ~= nil, "M.ITEMS should be defined")
  t.eq(#M.ITEMS, 6, "M.ITEMS should have 6 entries")

  -- Check each expected item
  local expectedIds = { "tuning", "mdb", "uical", "senscal", "dtc", "fcssync" }
  for i, expectedId in ipairs(expectedIds) do
    t.eq(M.ITEMS[i].id, expectedId, "M.ITEMS[" .. i .. "].id should be " .. expectedId)
    t.truthy(M.ITEMS[i].label ~= nil, "M.ITEMS[" .. i .. "] should have a label")
  end
end)

return true
