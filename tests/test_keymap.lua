-- tests/test_keymap.lua
local t = require("tests.framework")
local keymap = require("fcs.input.keymap")

-- Synthetic map using raw numeric codes so the test does not depend on the keys API.
local M = {
  [1] = {axis="yaw",  dir=-1}, [2] = {axis="yaw",  dir=1},
  [3] = {axis="lift", dir=1},  [4] = {axis="lift", dir=-1},
  [5] = {axis="sway", dir=-1}, [6] = {axis="sway", dir=1},
  [7] = {axis="surge",dir=1},  [8] = {axis="surge",dir=-1},
}

t.test("keymap resolves each axis+dir to the right held flag", function()
  local h = keymap.resolve(M, {1,3,6,7})
  t.truthy(h.yawLeft, "yawLeft"); t.truthy(h.up, "up")
  t.truthy(h.swayRight, "swayRight"); t.truthy(h.surgeFwd, "surgeFwd")
  t.eq(h.yawRight, nil, "yawRight unset")
  t.eq(h.down, nil, "down unset")
end)

t.test("keymap ignores unmapped codes and empty input", function()
  local h = keymap.resolve(M, {99, 100})
  t.eq(next(h), nil, "no flags for unmapped")
  local e = keymap.resolve(M, {})
  t.eq(next(e), nil, "no flags for empty")
end)

t.test("keymap.default exists and maps WASD/QE/RF", function()
  t.truthy(keymap.default[keys.w], "w mapped")
  t.truthy(keymap.default[keys.q], "q mapped")
  t.truthy(keymap.default[keys.r], "r mapped")
end)
