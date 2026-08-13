-- tests/test_buildloop_modes.lua
local t = require("tests.framework")
local hover = require("tools.hover_test")

t.test("buildLoop returns a loop plus the mode registry, PRECISION active", function()
  local backend = { sensors = function() return { onGround = true } end }
  local loop, reg = hover.buildLoop(backend)
  t.truthy(loop and reg, "returns loop and registry")
  t.eq(reg.default, "PRECISION", "default mode PRECISION")
  t.truthy(reg.byId.PRECISION and reg.byId.MAN and reg.byId.CRUISE, "all modes present")
  t.eq(loop.scheme, reg.byId.PRECISION.scheme, "loop starts on PRECISION scheme")
end)
