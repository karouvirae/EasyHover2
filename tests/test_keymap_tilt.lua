-- tests/test_keymap_tilt.lua
local t = require("tests.framework")
local keymap = require("fcs.input.keymap")

t.test("arrow keys resolve to pitch/roll held flags", function()
  local h = keymap.resolve(keymap.default, { keys.up, keys.right })
  -- MAN pitch flip (Task 5): Up = nose-down, Down = nose-up (was inverted before).
  t.truthy(h.pitchDown, "up => pitchDown (flipped)"); t.truthy(h.rollRight, "right => rollRight")
  t.eq(h.pitchUp, nil, "up unset"); t.eq(h.rollLeft, nil, "left unset")
end)
