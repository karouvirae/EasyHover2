-- tests/test_gfxpicker.lua
-- FLIGHT-styled modal picker (ui/basalt/instruments/gfxpicker.lua): real-CraftOS-PC Basalt probe.
local t = require("tests.framework")
local M = require("ui.basalt.instruments.gfxpicker")
local BasaltApp = require("ui.basalt.app")

local OPTS8 = {}
for i, n in ipairs({ "Plant Oil 20%", "Ethanol 200%", "Biodiesel 60%", "Sulfurized Diesel 75%",
                     "Diesel 80%", "Gasoline 125%", "Kerosene 150%", "Turpentine 30%" }) do
  OPTS8[i] = { text = n, value = n:match("^%S+") }
end

t.test("make: builds no elements until first show (lazy)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = M.make(frame)
  t.eq(ctrl.elements, nil, "no overlay built before show")
  t.eq(ctrl.visible(), false)
end)

t.test("show/hide: overlay becomes visible then hidden; construction + render do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = M.make(frame)
  local ok, err = pcall(ctrl.show, { title = "FUEL", options = OPTS8, current = "Biodiesel" })
  t.truthy(ok, "show should not error: " .. tostring(err))
  t.eq(ctrl.visible(), true)
  t.truthy(ctrl.elements ~= nil and ctrl.elements.overlay ~= nil, "overlay exists after show")
  t.truthy(#ctrl.elements.rowChips >= 1, "at least one row chip built")
  local ok2 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok2, "one render pass should not error")
  ctrl.hide()
  t.eq(ctrl.visible(), false)
end)

t.test("pick: fires onPick with the option value and hides", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local got
  local ctrl = M.make(frame)
  ctrl.show({ title = "FUEL", options = OPTS8, current = "Biodiesel",
              onPick = function(value) got = value end })
  ctrl.pick(5)  -- Diesel
  t.eq(got, "Diesel")
  t.eq(ctrl.visible(), false, "picking hides the modal")
end)

t.test("show: current selection's chip is green, others are not", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = M.make(frame)
  ctrl.show({ title = "FUEL", options = OPTS8, current = "Biodiesel" })
  -- Biodiesel is index 3 in OPTS8; on a frame tall enough to show all 8 with no scroll,
  -- row chip 3 is green and row chip 1 is not.
  t.eq(ctrl.elements.rowChips[3].chip:getBackground(), colors.green)
  t.truthy(ctrl.elements.rowChips[1].chip:getBackground() ~= colors.green)
end)
