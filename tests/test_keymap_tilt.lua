-- tests/test_keymap_tilt.lua
local t = require("tests.framework")
local keymap = require("fcs.input.keymap")

t.test("arrow keys resolve to pitch/roll held flags", function()
  local h = keymap.resolve(keymap.default, { keys.up, keys.right })
  t.truthy(h.pitchUp, "up => pitchUp"); t.truthy(h.rollRight, "right => rollRight")
  t.eq(h.pitchDown, nil, "down unset"); t.eq(h.rollLeft, nil, "left unset")
end)
