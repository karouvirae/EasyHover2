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

t.test("picker builds a trigger, reflects current, refreshes options, renders", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local picked
  local p = Picker.make(frame, {
    x = 2, y = 2, width = 12,
    options = { { text = "thruster_2", value = "thruster_2" }, { text = "gimbal_0", value = "gimbal_0" } },
    current = "gimbal_0",
    placeholder = "bind...",
    onPick = function(v) picked = v end,
  })
  t.truthy(p.trigger, "returns the trigger button")
  t.eq(p.selectedItem().value, "gimbal_0", "current reflected")
  t.eq(p.getValue(), "gimbal_0", "getValue == current value")

  p.setOptions({ { text = "relay_1", value = "relay_1" } }, "relay_1")
  t.eq(p.selectedItem().value, "relay_1", "options refreshed + new current selected")

  -- Reused options table across setOptions must reflect the new current.
  local shared = { { text = "x", value = "x" }, { text = "y", value = "y" } }
  p.setOptions(shared, "x"); t.eq(p.getValue(), "x")
  p.setOptions(shared, "y"); t.eq(p.getValue(), "y", "reused table -> follows new current")

  -- Opening the overlay and tapping a row fires the picker's own onPick with the exact value.
  p.overlay.show({ options = shared, current = "y", onPick = function(v) picked = v end })
  p.overlay.pick(1)  -- tap "x"
  t.eq(picked, "x", "overlay pick fires onPick with the row value")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("unbound current (no matching option) -> selectedItem nil, getValue nil", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local p = Picker.make(frame, {
    x = 1, y = 1, width = 10,
    options = { { text = "(none)", value = false }, { text = "a", value = "a" } },
    current = nil, placeholder = "(none)", onPick = function() end,
  })
  t.eq(p.selectedItem(), nil, "current nil matches no option -> nil")
  t.eq(p.getValue(), nil)
  p.setOptions({ { text = "(none)", value = false } }, false)
  t.eq(p.getValue(), false, "(none) is value=false, a real match")
end)

t.test("setEnabled toggles the trigger without error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local p = Picker.make(frame, { x = 1, y = 1, width = 8, options = {}, current = false, onPick = function() end })
  local ok = pcall(function() p.setEnabled(false); p.setEnabled(true) end)
  t.truthy(ok, "setEnabled must not error")
end)
