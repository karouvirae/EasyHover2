package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Geo = require("nav.lib.geometry")

t.test("a good non-coplanar, well-separated 4-beacon set is usable", function()
  local beacons = { { x = 0, y = 0, z = 0 }, { x = 200, y = 2, z = 0 },
                    { x = 0, y = 1, z = 200 }, { x = 60, y = 150, z = 60 } }
  local g = Geo.grade(beacons)
  t.truthy(g.usable, "4 non-coplanar hosts -> usable")
  t.eq(g.usableHosts, 4)
end)

t.test("fewer than 4 hosts is unusable", function()
  local g = Geo.grade({ { x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 0 }, { x = 0, y = 10, z = 0 } })
  t.truthy(not g.usable)
  t.eq(g.usableHosts, 3)
end)

t.test("a coplanar 4-beacon set (flat ring) is unusable -- mirror cannot be resolved", function()
  local beacons = { { x = 0, y = 70, z = 0 }, { x = 200, y = 70, z = 0 },
                    { x = 0, y = 70, z = 200 }, { x = 200, y = 70, z = 200 } }
  local g = Geo.grade(beacons)
  t.truthy(not g.usable)
end)

t.test("beacons within 1 block of each other collapse to one host", function()
  local beacons = { { x = 0, y = 0, z = 0 }, { x = 0.5, y = 0, z = 0 }, -- within MIN_SEPARATION
                    { x = 0, y = 10, z = 0 }, { x = 60, y = 150, z = 60 } }
  local g = Geo.grade(beacons)
  t.truthy(g.usableHosts < 4, "the near-duplicate does not count twice")
end)
