-- tests/test_panels_fcs_modes.lua
-- Task 12: pure logic for the PRECISION/MAN/CRUISE flight-mode selector on the FCS cockpit page.
-- M.MODES / M.action(id) / M.modeActive(ctx, id) -- no Basalt, no peripherals.
local t = require("tests.framework")
local F = require("ui.panels.fcs")

t.test("mode list + action factory", function()
  t.eq(#F.MODES, 5, "five modes: PRECISION/MAN/CRUISE/CPL/DCPL")
  t.eq(F.action("MAN").k, "flightMode", "action is a flightMode command")
  t.eq(F.action("MAN").id, "MAN", "carries the id")
end)

t.test("modeActive reflects reported flightMode only (no optimism)", function()
  t.truthy(F.modeActive({ flightMode = "CRUISE" }, "CRUISE"), "reported mode is active")
  t.eq(F.modeActive({ flightMode = "CRUISE" }, "MAN"), false, "others inactive")
  t.eq(F.modeActive({}, "PRECISION"), false, "no report => nothing active")
end)

t.test("MODES includes CPL and DCPL and action returns their flightMode command", function()
  local has = {}; for _, id in ipairs(F.MODES) do has[id] = true end
  t.truthy(has.CPL and has.DCPL, "CPL/DCPL selectable")
  t.eq(F.action("CPL").k, "flightMode", "CPL action is a flightMode command")
  t.eq(F.action("DCPL").id, "DCPL", "DCPL id carried")
end)
