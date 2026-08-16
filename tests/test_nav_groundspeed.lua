package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local NR = require("nav.runtime")

t.test("groundSpeed is horizontal distance over dt, ignoring y", function()
  local gs = NR.groundSpeed({ x = 0, y = 0, z = 0 }, 1000, { x = 3, y = 100, z = 4 }, 2000) -- 5 blk / 1 s
  t.truthy(math.abs(gs - 5) < 1e-9, "5 blk/s (y ignored): " .. tostring(gs))
end)

t.test("groundSpeed is nil on first fix / nil fix / non-positive dt", function()
  t.eq(NR.groundSpeed(nil, nil, { x = 1, y = 0, z = 1 }, 1000), nil, "no previous fix")
  t.eq(NR.groundSpeed({ x = 0, y = 0, z = 0 }, 1000, nil, 2000), nil, "no current fix")
  t.eq(NR.groundSpeed({ x = 0, y = 0, z = 0 }, 2000, { x = 1, y = 0, z = 0 }, 2000), nil, "dt = 0")
end)
