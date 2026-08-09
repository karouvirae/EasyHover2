package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local TD = require("fcs.io.tuningdefaults")

t.test("tuning defaults expose gains/caps/feel as a deep-copied table", function()
  local a, b = TD.get(), TD.get()
  t.eq(type(a.gains), "table")
  t.eq(type(a.caps), "table")
  t.eq(type(a.feel), "table")
  a.gains.__scratch = 1
  t.eq(b.gains.__scratch, nil, "get() returns an independent copy")
  t.truthy(a.gains.yaw and a.caps.pitch and a.feel.climbRate, "carries known keys")
end)
