-- tests/test_page_config.lua
-- CONFIG cockpit page (ui/basalt/pages/config.lua) -- the MONITOR SELECTION manager. Covers the
-- PURE list-memory seams (no Basalt / peripherals): monNum, rowText, mergeDiscovered, removeAt,
-- forget, _assignOptions. The Basalt element tree + drawing is verified by the render pipeline
-- (tools/render) and in-world, not here.
local t = require("tests.framework")
local M = require("ui.basalt.pages.config")

-- ===== monNum: trailing peripheral number -> zero-padded 2-digit "<XX>" =====

t.test("monNum: monitor_1 -> 01", function() t.eq(M.monNum("monitor_1"), "01") end)
t.test("monNum: monitor_10 -> 10", function() t.eq(M.monNum("monitor_10"), "10") end)
t.test("monNum: monitor_0 -> 00", function() t.eq(M.monNum("monitor_0"), "00") end)
t.test("monNum: no trailing number -> ??", function() t.eq(M.monNum("left"), "??") end)

-- ===== rowText: "Monitor <XX> -[  ]-   ==   {PANEL}" =====

t.test("rowText: shows the panel in uppercase", function()
  t.truthy(M.rowText("monitor_1", "nav"):find("Monitor <01>", 1, true), "has the padded id")
  t.truthy(M.rowText("monitor_1", "nav"):find("{NAV}", 1, true), "panel uppercased in braces")
end)

t.test("rowText: unassigned monitor shows ---- for the panel", function()
  t.truthy(M.rowText("monitor_3", nil):find("{----}", 1, true), "no panel -> {----}")
end)

-- ===== mergeDiscovered: add newly-seen monitors, keep existing order/slots =====

t.test("mergeDiscovered appends only unseen monitors, preserving order", function()
  local order = { "monitor_0", "monitor_1" }
  M.mergeDiscovered(order, { "monitor_1", "monitor_5", "monitor_0", "monitor_2" })
  t.eq(order[1], "monitor_0"); t.eq(order[2], "monitor_1")
  t.eq(order[3], "monitor_5"); t.eq(order[4], "monitor_2")
  t.eq(#order, 4, "no duplicates of already-known monitors")
end)

-- ===== removeAt: drop one index from the list =====

t.test("removeAt removes the given index", function()
  local order = { "a", "b", "c" }
  M.removeAt(order, 2)
  t.eq(order[1], "a"); t.eq(order[2], "c"); t.eq(#order, 2)
end)

t.test("removeAt out of range is a no-op", function()
  local order = { "a" }
  M.removeAt(order, 5); M.removeAt(order, 0)
  t.eq(#order, 1)
end)

-- ===== forget: DEL both forgets the list slot AND clears its panel assignment =====
-- (frames are built from config.assign, not monitorOrder, so a forgotten monitor MUST lose its
--  assignment or it would keep rendering after being DEL'd.)

t.test("forget removes the list slot and clears that monitor's assignment", function()
  local order  = { "monitor_0", "monitor_1", "monitor_5" }
  local assign = { monitor_0 = "flight", monitor_1 = "nav", monitor_5 = "pfd" }
  M.forget(order, assign, 2)                    -- forget monitor_1
  t.eq(#order, 2, "slot removed from the list")
  t.eq(order[1], "monitor_0"); t.eq(order[2], "monitor_5")
  t.eq(assign.monitor_1, nil, "its assignment is cleared")
  t.eq(assign.monitor_0, "flight", "other assignments untouched")
  t.eq(assign.monitor_5, "pfd")
end)

t.test("forget out of range clears nothing", function()
  local order  = { "monitor_0" }
  local assign = { monitor_0 = "flight" }
  M.forget(order, assign, 9)
  t.eq(#order, 1); t.eq(assign.monitor_0, "flight")
end)

-- ===== _assignOptions: the SET UI picker options =====

t.test("_assignOptions leads with (none) then the assign cycle", function()
  local opts = M._assignOptions()
  t.eq(opts[1].text, "(none)"); t.eq(opts[1].value, false)
  t.eq(opts[2].value, M.ASSIGN_CYCLE[1], "first real option is the first cycle entry")
  t.eq(#opts, #M.ASSIGN_CYCLE + 1, "(none) + every cycle entry")
end)
