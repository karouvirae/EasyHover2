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

t.test("pdop is low when the constellation surrounds the receiver in 3D", function()
  local hosts = { { x = 100, y = 0, z = 0 }, { x = -100, y = 0, z = 0 },
                  { x = 0, y = 100, z = 0 }, { x = 0, y = 0, z = 100 } }
  local d = Geo.pdop(hosts, { x = 0, y = 0, z = 0 })
  t.truthy(d ~= nil and d < 3, "good geometry -> low PDOP (" .. tostring(d) .. ")")
end)

t.test("pdop is high for beacons clustered far to one side (the in-game GDOP bug)", function()
  local hosts = { { x = -34, y = 89, z = 2753 }, { x = 66, y = 95, z = 2654 },
                  { x = 41, y = 98, z = 2741 }, { x = 99, y = -45, z = 2768 } }
  local d = Geo.pdop(hosts, { x = 825, y = 79, z = 2928 })
  t.truthy(d ~= nil and d > 8, "distant clustered geometry -> high PDOP (" .. tostring(d) .. ")")
end)

t.test("pdop needs 4 hosts", function()
  t.eq(Geo.pdop({ { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 } },
    { x = 0, y = 0, z = 0 }), nil)
end)

t.test("hdop stays low for a wide, flat constellation even when pdop explodes", function()
  -- The real in-game case: beacons spread far HORIZONTALLY but all near the same build height.
  -- Vertical dilution is irreducibly huge (you can't spread beacons km's vertically in MC), but
  -- the HORIZONTAL geometry -- all that matters for a hovercraft's nav -- is excellent.
  local hosts = { { x = -7737, y = -54, z = 7579 }, { x = 6462, y = 200, z = 6107 },
                  { x = 7144, y = 65, z = -7266 }, { x = -7210, y = 64, z = -7260 } }
  local at = { x = 824, y = 86, z = 2922 }
  local p = Geo.pdop(hosts, at)
  local h = Geo.hdop(hosts, at)
  t.truthy(p ~= nil and p > 50, "3D PDOP is huge for a flat constellation (" .. tostring(p) .. ")")
  t.truthy(h ~= nil and h < 3, "but HDOP is low -- horizontal geometry is excellent (" .. tostring(h) .. ")")
end)

t.test("hdop is high for beacons clustered horizontally to one side", function()
  local hosts = { { x = -34, y = 89, z = 2753 }, { x = 66, y = 95, z = 2654 },
                  { x = 41, y = 98, z = 2741 }, { x = 99, y = -45, z = 2768 } }
  local h = Geo.hdop(hosts, { x = 825, y = 79, z = 2928 })
  t.truthy(h ~= nil and h > 8, "distant horizontally-clustered geometry -> high HDOP (" .. tostring(h) .. ")")
end)

t.test("hdop needs 4 hosts", function()
  t.eq(Geo.hdop({ { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 } },
    { x = 0, y = 0, z = 0 }), nil)
end)

t.test("a horizontally-degenerate (near-collinear in x/z) set is still caught -- quality 0", function()
  -- 4 hosts spread along x with only a hair of z separation (varied y keeps the full 3D matrix
  -- non-singular). Horizontal geometry is ill-conditioned, so HDOP is huge and quality collapses to
  -- 0 -- proving the "coplanarity decoupling still catches bad HORIZONTAL geometry" guarantee.
  local hosts = { { x = 0, y = 0, z = 0 }, { x = 500, y = 40, z = 0 },
                  { x = 1000, y = -30, z = 1 }, { x = 1500, y = 20, z = -1 } }
  local h = Geo.hdop(hosts, { x = 750, y = 10, z = 0 })
  t.truthy(h ~= nil and h > 50, "near-collinear horizontal geometry -> huge HDOP (" .. tostring(h) .. ")")
  t.eq(Geo.dopQuality(h).quality, 0, "and quality collapses to 0")
end)

t.test("dopQuality maps PDOP to a 0..1 confidence and a block error estimate", function()
  local good = Geo.dopQuality(1.5)
  t.truthy(good.quality > 0.9, "low PDOP -> high quality")
  t.eq(Geo.dopQuality(20).quality, 0, "very high PDOP -> zero quality")
  t.near(Geo.dopQuality(4, 0.5).errorEst, 2.0, 1e-9, "errorEst = pdop * uere")
end)

t.test("beacons within 1 block of each other collapse to one host", function()
  local beacons = { { x = 0, y = 0, z = 0 }, { x = 0.5, y = 0, z = 0 }, -- within MIN_SEPARATION
                    { x = 0, y = 10, z = 0 }, { x = 60, y = 150, z = 60 } }
  local g = Geo.grade(beacons)
  t.truthy(g.usableHosts < 4, "the near-duplicate does not count twice")
end)
