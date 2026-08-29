-- tests/test_panels_fcs_modes.lua
-- Task 12: pure logic for the PRECISION/MAN/CRUISE flight-mode selector on the FCS cockpit page.
-- Task 10: flight modes (M.MODES) and master modes (M.MASTERS) are now two separate exclusive
-- groups -- M.MODES / M.action(id) / M.modeActive(ctx, id) for flight; M.MASTERS / M.masterActive
-- for CPL/DCPL -- no Basalt, no peripherals.
local t = require("tests.framework")
local F = require("ui.panels.fcs")

t.test("mode list + action factory", function()
  t.eq(#F.MODES, 5, "five flight modes: PRECISION/MAN/CRUISE/LDG/DRN")
  t.eq(F.action("MAN").k, "flightMode", "action is a flightMode command")
  t.eq(F.action("MAN").id, "MAN", "carries the id")
end)

t.test("modeActive reflects reported flightMode only (no optimism)", function()
  t.truthy(F.modeActive({ flightMode = "CRUISE" }, "CRUISE"), "reported mode is active")
  t.eq(F.modeActive({ flightMode = "CRUISE" }, "MAN"), false, "others inactive")
  t.eq(F.modeActive({}, "PRECISION"), false, "no report => nothing active")
end)

t.test("MODES includes LDG and DRN and action returns their flightMode command", function()
  local has = {}; for _, id in ipairs(F.MODES) do has[id] = true end
  t.truthy(has.LDG, "LDG selectable")
  t.truthy(has.DRN, "DRN selectable")
  t.eq(F.action("LDG").k, "flightMode", "LDG emits flightMode cmd")
  t.eq(F.action("LDG").id, "LDG", "LDG id")
  t.eq(F.action("DRN").id, "DRN", "DRN id")
  t.eq(F.MODE_LABEL.LDG, "LDG", "LDG label")
  t.eq(F.MODE_LABEL.DRN, "DRN", "DRN label")
  t.eq(F.modeActive({ flightMode = "LDG" }, "LDG"), true, "LDG active")
  t.eq(F.modeActive({ flightMode = "DRN" }, "DRN"), true, "DRN active")
end)

t.test("panels/fcs: split selectors -- 5 flight modes, 2 master modes", function()
  local set = {} for _, id in ipairs(F.MODES) do set[id] = true end
  t.truthy(not set.CPL and not set.DCPL, "CPL/DCPL not flight modes")
  t.eq(#F.MASTERS, 2, "two master modes")
  t.eq(F.action("DCPL").k, "masterMode", "master id -> masterMode command")
  t.eq(F.action("DCPL").id, "DCPL", "master id carried")
  t.eq(F.action("PRECISION").k, "flightMode", "flight id -> flightMode command")
  t.truthy(F.masterActive({ masterMode = "CPL" }, "CPL"), "masterActive reads masterMode")
  t.truthy(not F.masterActive({ masterMode = "CPL" }, "DCPL"), "masterActive exclusive")
  t.truthy(F.trimActive({ masterMode = "DCPL" }), "trim active with a master set")
  t.truthy(not F.trimActive({}), "trim inactive with no reported master yet")
end)
