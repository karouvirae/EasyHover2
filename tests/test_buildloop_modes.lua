-- tests/test_buildloop_modes.lua
local t = require("tests.framework")
local hover = require("tools.hover_test")

t.test("buildLoop returns a loop plus the mode registry, LDG active", function()
  local backend = { sensors = function() return { onGround = true } end }
  local loop, reg = hover.buildLoop(backend)
  t.truthy(loop and reg, "returns loop and registry")
  t.eq(reg.default, "LDG", "default mode LDG")
  t.truthy(reg.byId.PRECISION and reg.byId.MAN and reg.byId.CRUISE, "all modes present")
  t.truthy(reg.byId.LDG and reg.byId.DRN, "LDG/DRN present")
  t.eq(loop.scheme, reg.byId.LDG.scheme, "loop starts on LDG scheme")
end)
