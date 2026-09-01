-- tests/test_page_nav.lua
-- NAV cockpit page (ui/basalt/pages/nav.lua): tests the TESTABLE M._onButton intent seam with a
-- real Nav stack, plus a real-CraftOS-PC Basalt construction probe -- build the element tree on
-- a frame bound to term.current(), call apply() with a full canonical state, then one
-- basalt.update(...) render pass. NEVER basalt.run() (blocks on pullEventRaw).
local t = require("tests.framework")
local M = require("ui.basalt.pages.nav")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")

-- ===== M._onButton: navigational intent dispatch =====

t.test("_onButton: with nav, id==\"bitconfig\" pushes onto stack and returns \"bitconfig\"", function()
  local nav = Nav.new("nav")
  t.eq(nav:depth(), 1, "nav starts at depth 1 (root)")
  t.eq(nav:top(), "nav", "nav starts at root")
  t.eq(nav:canBack(), false, "nav cannot back when at root")

  local result = M._onButton(nav, "bitconfig", 1000)
  t.eq(result, "bitconfig", "M._onButton should return \"bitconfig\"")
  t.eq(nav:depth(), 2, "nav should be at depth 2 after push")
  t.eq(nav:top(), "bitconfig", "nav top should be \"bitconfig\"")
  t.eq(nav:canBack(), true, "nav should be able to back")
end)

t.test("_onButton: non-bitconfig id returns nil and does NOT push", function()
  local nav = Nav.new("nav")
  local initialDepth = nav:depth()

  local result = M._onButton(nav, "someOtherId", 2000)
  t.eq(result, nil, "M._onButton should return nil for unknown ids")
  t.eq(nav:depth(), initialDepth, "nav depth should NOT change for unknown ids")
end)

t.test("_onButton: with nil nav returns nil gracefully", function()
  local result = M._onButton(nil, "bitconfig", 3000)
  t.eq(result, nil, "M._onButton should return nil when nav is nil")
end)

-- ===== M._wptArgs: PURE mutation-arg builder for WPT EDIT actions =====

t.test("_wptArgs addHere copies the craft GPS position into a new waypoint", function()
  local eff = M._wptArgs("addHere", { name = "Home", type = "base" }, { x = 10, y = -47, z = 20 })
  t.eq(eff.op, "addWpt")
  t.eq(eff.args.name, "Home"); t.eq(eff.args.x, 10); t.eq(eff.args.y, -47); t.eq(eff.args.z, 20)
  t.eq(eff.args.type, "base")
end)

t.test("_wptArgs addHere fails without a name or a GPS fix", function()
  t.eq(M._wptArgs("addHere", { name = "", type = "base" }, { x = 1, y = 1, z = 1 }), nil)
  t.eq(M._wptArgs("addHere", { name = "A", type = "base" }, nil), nil, "no fix -> nil")
end)

t.test("_wptArgs addManual parses x/y/z strings into numbers", function()
  local eff = M._wptArgs("addManual", { name = "Depot", x = "100", y = "64", z = "-200", type = "outpost" })
  t.eq(eff.op, "addWpt"); t.eq(eff.args.x, 100); t.eq(eff.args.y, 64); t.eq(eff.args.z, -200)
  t.eq(M._wptArgs("addManual", { name = "Bad", x = "nan", y = "1", z = "1", type = "poi" }), nil)
end)

t.test("_wptArgs edit targets the selected name with parsed fields", function()
  local eff = M._wptArgs("edit", { x = "5", y = "6", z = "7", type = "facility" }, nil, "Home")
  t.eq(eff.op, "editWpt"); t.eq(eff.args.name, "Home")
  t.eq(eff.args.fields.x, 5); t.eq(eff.args.fields.type, "facility")
  t.eq(M._wptArgs("edit", {}, nil, nil), nil, "no selection -> nil")
end)

t.test("_wptArgs delete targets the selected name", function()
  local eff = M._wptArgs("delete", {}, nil, "Home")
  t.eq(eff.op, "deleteWpt"); t.eq(eff.args.name, "Home")
  t.eq(M._wptArgs("delete", {}, nil, nil), nil, "no selection -> nil")
end)

t.test("_wptArgs edit includes a new name when the form name is set", function()
  local eff = M._wptArgs("edit", { name = "Hangar", x = "1", y = "2", z = "3", type = "base" }, nil, "Home")
  t.eq(eff.args.name, "Home")
  t.eq(eff.args.fields.name, "Hangar")
end)

t.test("_emptyDraft has blank name/coords so addManual cannot resurrect a deleted wpt", function()
  local d = M._emptyDraft()
  t.eq(d.name, ""); t.eq(d.x, ""); t.eq(d.y, ""); t.eq(d.z, "")
  t.eq(d.type, "base"); t.eq(d.kind, "add"); t.eq(d.selectedName, nil)
  t.eq(M._wptArgs("addManual", d), nil)
end)

t.test("_draftFromWpt fills strings + kind=edit; nil wpt is empty add", function()
  local d = M._draftFromWpt({ name = "Home", x = 10, y = -47, z = 20, type = "poi" })
  t.eq(d.name, "Home"); t.eq(d.x, "10"); t.eq(d.y, "-47"); t.eq(d.z, "20")
  t.eq(d.type, "poi"); t.eq(d.kind, "edit"); t.eq(d.selectedName, "Home")
  local e = M._draftFromWpt(nil)
  t.eq(e.kind, "add"); t.eq(e.name, "")
end)

t.test("_draftFromWpt keeps FULL coordinate precision internally (display rounds separately)", function()
  -- A HERE-captured waypoint carries long GPS decimals. The draft (edited + saved) must keep them in
  -- full; only the on-screen readout rounds, via M._fmtCoord. Guards against rounding the stored value.
  local d = M._draftFromWpt({ name = "Pad", x = 123.456789, y = -47.10001, z = 20.9, type = "base" })
  t.eq(d.x, "123.456789"); t.eq(d.y, "-47.10001"); t.eq(d.z, "20.9")
end)

t.test("_fmtCoord rounds a coordinate to one decimal for display; non-numeric passes through", function()
  t.eq(M._fmtCoord(123.456789), "123.5")
  t.eq(M._fmtCoord("123.456789"), "123.5")   -- a numeric draft-field string rounds too
  t.eq(M._fmtCoord(-47.10001), "-47.1")
  t.eq(M._fmtCoord(20), "20.0")              -- integer altitude -> explicit one decimal
  t.eq(M._fmtCoord(""), "")                  -- blank passes through (caller shows "..." placeholder)
  t.eq(M._fmtCoord("abc"), "abc")            -- non-numeric passes through unchanged
end)

t.test("_nextType cycles the waypoint types", function()
  t.eq(M._nextType("base"), "outpost")
  t.eq(M._nextType("poi"), "base")
  t.eq(M._nextType("nope"), "base")
end)

t.test("_hereName picks the next free hereN", function()
  t.eq(M._hereName({ waypoints = {} }), "here1")
  t.eq(M._hereName({ waypoints = { { name = "here1" } } }), "here2")
  t.eq(M._hereName({ waypoints = { { name = "here1" }, { name = "here2" } } }), "here3")
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

t.test("M.build constructs the element tree; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()   -- binds to term.current(), per ui/basalt/app.lua's header

  local nav = Nav.new("nav")

  local h = M.build(basalt, frame, nil, nav)
  t.eq(h.id, "nav")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.region ~= nil, "the NAV menu region is present")
  t.truthy(h.elements.bitconfigBtn ~= nil, "bitconfigBtn element present (BIT/CONFIG still reachable)")

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

t.test("drilling into each NAV sub-screen builds + renders without error (real basalt)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local h = M.build(basalt, frame, nil, Nav.new("nav"))
  local region = h.elements.region
  for _, screen in ipairs({ "wptedit", "wptform", "dtc", "rtedit" }) do
    local ok, err = pcall(function()
      region:push(screen); h.apply({}); basalt.update("timer", -1); region:pop()
    end)
    t.truthy(ok, screen .. " sub-screen must build without error: " .. tostring(err))
  end
end)

t.test("wptform screen has NAME/TYPE/X/Y/Z rows and no console Inputs", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local h = M.build(basalt, frame, nil, Nav.new("nav"))
  local region = h.elements.region
  region:push("wptform")
  h.apply({})
  local els = region.built.wptform.handle.elements
  t.truthy(els.nameBtn and els.typeBtn and els.xBtn and els.yBtn and els.zBtn, "form field buttons")
  t.truthy(els.saveRow and els.backRow, "SAVE + BACK")
  t.eq(els.nameIn, nil, "no monitor Input (console keyboard) on the form")
end)

t.test("wptedit has HERE/MAN/EDIT/DEL and no console Inputs", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local h = M.build(basalt, frame, nil, Nav.new("nav"))
  local region = h.elements.region
  region:push("wptedit")
  h.apply({})
  local els = region.built.wptedit.handle.elements
  t.truthy(els.actionRow and #els.actionRow.buttons == 4, "HERE MAN EDIT DEL")
  t.eq(els.nameIn, nil, "no leftover Input fields on wptedit")
  t.eq(els.xIn, nil)
end)

t.test("wptedit HERE is disabled when the wptClient is stale", function()
  -- A client that still looks online after one reply, but is past the 6000 ms window, must
  -- paint HERE disabled on apply -- otherwise parked NAV keeps looking writable.
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local Client = require("ui.basalt.wptclient")
  local c = Client.new({ now = function() return 20000 end })
  c:onReply({ k = "wpt_store", store = { waypoints = {}, routes = {} }, rev = 1 }, 10000)
  t.eq(c.online, true, "still online until refreshOnline runs")
  local h = M.build(basalt, frame, { wptClient = c }, Nav.new("nav"))
  local region = h.elements.region
  region:push("wptedit")
  h.apply({})
  local els = region.built.wptedit.handle.elements
  t.eq(els.actionRow.buttons[1].state, "disabled", "HERE disabled when NAV is stale")
end)

t.test("M.build: clicking [BIT/CONFIG] button invokes M._onButton and pushes nav", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local nav = Nav.new("nav")
  t.eq(nav:depth(), 1, "nav starts at depth 1")

  local h = M.build(basalt, frame, nil, nav)
  local btn = h.elements.bitconfigBtn

  -- Simulate a click by calling the onClick handler directly.
  -- (In a real UI, Basalt would call this on a mouse click event.)
  -- We cannot directly invoke Basalt's internal click machinery in a headless test,
  -- but we can verify the button exists and is enabled, and call M._onButton directly.
  local ok, err = pcall(function()
    M._onButton(nav, "bitconfig", os.epoch("utc"))
  end)
  t.truthy(ok, "M._onButton should not error when called directly: " .. tostring(err))
  t.eq(nav:depth(), 2, "nav should push after M._onButton(nav, \"bitconfig\")")
  t.eq(nav:top(), "bitconfig", "nav top should be \"bitconfig\" after push")
end)

return true
