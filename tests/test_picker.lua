-- tests/test_picker.lua
local t = require("tests.framework")
local Picker = require("ui.basalt.picker")
local BasaltApp = require("ui.basalt.app")

t.test("indexOf finds the option matching the current value", function()
  local opts = { { text = "A", value = "a" }, { text = "B", value = "b" }, { text = "C", value = "c" } }
  t.eq(Picker.indexOf(opts, "b"), 2)
  t.eq(Picker.indexOf(opts, "a"), 1)
  t.eq(Picker.indexOf(opts, "zzz"), nil, "no match -> nil")
  t.eq(Picker.indexOf({}, "a"), nil, "empty -> nil")
end)

t.test("picker builds a dropdown, reflects current, refreshes options, renders", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local picked
  local p = Picker.make(frame, {
    x = 2, y = 2, width = 12, dropdownHeight = 5,
    options = { { text = "thruster_2", value = "thruster_2" }, { text = "gimbal_0", value = "gimbal_0" } },
    current = "gimbal_0",
    placeholder = "bind...",
    onPick = function(v) picked = v end,
  })
  t.truthy(p.dropdown, "returns the dropdown")
  t.eq(p.dropdown:getSelectedItem().value, "gimbal_0", "current reflected as the selected item")

  p.setOptions({ { text = "relay_1", value = "relay_1" } }, "relay_1")  -- refresh (e.g. after re-scan)
  t.eq(p.dropdown:getSelectedItem().value, "relay_1", "options refreshed + new current selected")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)
