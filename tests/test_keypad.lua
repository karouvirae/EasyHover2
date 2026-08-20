-- tests/test_keypad.lua
-- On-screen keypad (ui/basalt/keypad.lua): PURE M.apply / M.keys, plus a CraftOS-PC construction
-- probe. No Basalt at module load.
local t = require("tests.framework")
local K = require("ui.basalt.keypad")

t.test("apply name: appends letters and digits", function()
  t.eq(K.apply("", "H", "name"), "H")
  t.eq(K.apply("H", "o", "name"), "Ho")
  t.eq(K.apply("Home", "1", "name"), "Home1")
end)

t.test("apply name: BKSP deletes last char; empty stays empty", function()
  t.eq(K.apply("Home", "BKSP", "name"), "Hom")
  t.eq(K.apply("", "BKSP", "name"), "")
end)

t.test("apply num: digits and a leading minus; rejects letters", function()
  t.eq(K.apply("", "1", "num"), "1")
  t.eq(K.apply("12", "3", "num"), "123")
  t.eq(K.apply("", "-", "num"), "-")
  t.eq(K.apply("4", "-", "num"), "4", "minus only at start")
  t.eq(K.apply("-", "5", "num"), "-5")
  t.eq(K.apply("12", "A", "num"), "12")
end)

t.test("apply num: BKSP", function()
  t.eq(K.apply("-5", "BKSP", "num"), "-")
  t.eq(K.apply("-", "BKSP", "num"), "")
end)

t.test("keys name includes A-Z, 0-9, BKSP; keys num is digits/minus/BKSP", function()
  local name = K.keys("name")
  local set = {}
  for _, k in ipairs(name) do set[k] = true end
  t.truthy(set.A and set.Z and set["0"] and set["9"] and set.BKSP, "name keypad has letters+digits+BKSP")
  t.eq(set.OK, nil, "OK is chrome, not a buffer key")

  local num = K.keys("num")
  local nset = {}
  for _, k in ipairs(num) do nset[k] = true end
  t.truthy(nset["0"] and nset["9"] and nset["-"] and nset.BKSP)
  t.eq(nset.A, nil, "num keypad has no letters")
end)

local BasaltApp = require("ui.basalt.app")

t.test("make() is inert until show()", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = K.make(frame)
  t.eq(ctrl.visible(), false)
  t.eq(ctrl.elements, nil)
end)

t.test("show() + tap keys + OK fires onOk with the buffer", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = K.make(frame)
  local got
  ctrl.show({ title = "NAME", mode = "name", value = "Ho", onOk = function(v) got = v end })
  t.eq(ctrl.visible(), true)
  t.truthy(ctrl.elements and ctrl.elements.overlay)
  ctrl.tap("m")
  ctrl.tap("e")
  ctrl.ok()
  t.eq(got, "Home")
  t.eq(ctrl.visible(), false)
end)

t.test("value readout is not black-on-black and shows the buffer", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = K.make(frame)
  ctrl.show({ title = "NAME", mode = "name", value = "Home" })
  t.eq(ctrl.elements.value:getText(), "Home")
  t.eq(ctrl.elements.value:getBackground(), colors.white, "value sits on a white bar")
  t.eq(ctrl.elements.value:getForeground(), colors.black, "value text is black")
  t.eq(ctrl.elements.title:getText(), "NAME")
  t.eq(ctrl.elements.title:getForeground(), colors.white, "title is white on the black overlay")
end)

t.test("cancel hides without onOk; reuse keeps one overlay", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = K.make(frame)
  local got
  ctrl.show({ title = "X", mode = "num", value = "10", onOk = function(v) got = v end })
  local ov1 = ctrl.elements.overlay
  ctrl.cancel()
  t.eq(got, nil)
  t.eq(ctrl.visible(), false)
  ctrl.show({ title = "Y", mode = "num", value = "0", onOk = function() end })
  t.eq(ctrl.elements.overlay, ov1, "same overlay reused")
  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "render must not error: " .. tostring(err))
end)
