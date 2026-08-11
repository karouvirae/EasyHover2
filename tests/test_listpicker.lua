-- tests/test_listpicker.lua
local t = require("tests.framework")
local ListPicker = require("ui.basalt.listpicker")

t.test("formatLabel strips a leading namespace segment", function()
  t.eq(ListPicker.formatLabel("create:item_vault_12", 20), "item_vault_12")
  t.eq(ListPicker.formatLabel("minecraft:barrel_3", 20), "barrel_3")
end)

t.test("formatLabel keeps names without a namespace unchanged when they fit", function()
  t.eq(ListPicker.formatLabel("redstone_relay_4", 20), "redstone_relay_4")
  t.eq(ListPicker.formatLabel("top", 10), "top")
  t.eq(ListPicker.formatLabel("(none)", 10), "(none)")
end)

t.test("formatLabel front-truncates with ~ keeping the unique tail", function()
  t.eq(ListPicker.formatLabel("redstone_relay_4", 13), "~tone_relay_4")
  t.truthy(#ListPicker.formatLabel("redstone_relay_4", 13) <= 13, "never exceeds width")
  t.truthy(#ListPicker.formatLabel("create:item_vault_1234567", 8) <= 8, "never exceeds width (stripped+trunc)")
end)

t.test("formatLabel with no width returns the stripped full string", function()
  t.eq(ListPicker.formatLabel("create:item_vault_12", nil), "item_vault_12")
end)
