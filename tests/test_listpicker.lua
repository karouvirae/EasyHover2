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

local BasaltApp = require("ui.basalt.app")

t.test("make() is inert until show() (no Basalt built at make time)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = ListPicker.make(frame)
  t.eq(ctrl.visible(), false, "not visible before show")
  t.eq(ctrl.elements, nil, "no elements built before first show")
end)

t.test("show() builds the overlay, formats items, selects current, and is visible", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = ListPicker.make(frame)
  local picked
  ctrl.show({
    title = "BIND PUMP",
    options = {
      { text = "(none)", value = false },
      { text = "create:item_vault_7", value = "create:item_vault_7" },
      { text = "minecraft:barrel_3", value = "minecraft:barrel_3" },
    },
    current = "minecraft:barrel_3",
    onPick = function(v) picked = v end,
  })
  t.eq(ctrl.visible(), true, "overlay visible after show")
  t.truthy(ctrl.elements and ctrl.elements.list, "list element built")
  t.eq(ctrl.list:getSelectedItem().value, "minecraft:barrel_3", "current selected in the list")

  ctrl.pick(2)  -- tap the second option (create:item_vault_7)
  t.eq(picked, "create:item_vault_7", "pick(index) fires onPick with the row's value")
  t.eq(ctrl.visible(), false, "overlay hides after a pick")
end)

t.test("scrollBy changes the list offset; hide() hides; reuse keeps one overlay", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = ListPicker.make(frame)
  local opts = { title = "T", options = {}, current = false, onPick = function() end }
  for i = 1, 30 do opts.options[#opts.options + 1] = { text = "vault_" .. i, value = "vault_" .. i } end
  ctrl.show(opts)
  local ov1 = ctrl.elements.overlay
  ctrl.scrollBy(10)
  t.truthy(ctrl.list:getOffset() > 0, "offset advanced by scrollBy")
  ctrl.hide()
  t.eq(ctrl.visible(), false, "hidden")
  ctrl.show(opts)
  t.eq(ctrl.elements.overlay, ov1, "same overlay reused across show/hide (no accumulation)")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "render must not error: " .. tostring(err))
end)
