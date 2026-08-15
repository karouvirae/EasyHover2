package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local BR = require("beacon.runtime")

-- The mesh self-check: a beacon compares each peer's MEASURED range (CC modem distance) against the
-- geometric distance implied by both beacons' CONFIGURED coordinates. A typo in anyone's position
-- makes those disagree -> MISMATCH, which is how a mis-entered coordinate gets caught before it
-- silently ruins every NAV fix.

t.test("geoDistance is plain Euclidean distance", function()
  t.near(BR.geoDistance({ x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 0 }), 5, 1e-9)
end)

t.test("selfCheck passes when measured ranges match the configured geometry", function()
  local selfPos = { x = 0, y = 0, z = 0 }
  local peers = {
    B = { pos = { x = 30, y = 0, z = 0 }, dist = 30 },
    C = { pos = { x = 0, y = 0, z = 40 }, dist = 40 },
  }
  local r = BR.selfCheck(selfPos, peers)
  t.truthy(r.ok, "no mismatches")
  t.eq(r.checked, 2)
  t.eq(#r.mismatches, 0)
end)

t.test("selfCheck flags a beacon whose configured coordinates disagree with its measured range", function()
  local selfPos = { x = 0, y = 0, z = 0 }
  local peers = {
    B = { pos = { x = 30, y = 0, z = 0 }, dist = 30 },     -- consistent
    C = { pos = { x = 0, y = 0, z = 40 }, dist = 12 },     -- says 40 blocks away, measured 12 -> typo
  }
  local r = BR.selfCheck(selfPos, peers)
  t.truthy(not r.ok)
  t.eq(#r.mismatches, 1)
  t.eq(r.mismatches[1].id, "C")
  t.near(r.mismatches[1].expected, 40, 1e-9)
  t.near(r.mismatches[1].measured, 12, 1e-9)
end)

t.test("selfCheck skips peers heard without a measured distance", function()
  local r = BR.selfCheck({ x = 0, y = 0, z = 0 }, {
    B = { pos = { x = 30, y = 0, z = 0 }, dist = 30 },
    D = { pos = { x = 1, y = 1, z = 1 } },   -- no dist (cross-dimension) -> not checkable
  })
  t.eq(r.checked, 1)
  t.truthy(r.ok)
end)

t.test("a small measurement error within tolerance is not a mismatch", function()
  local r = BR.selfCheck({ x = 0, y = 0, z = 0 },
    { B = { pos = { x = 30, y = 0, z = 0 }, dist = 30.4 } }, 1.0)
  t.truthy(r.ok, "0.4 blocks < 1.0 tolerance")
end)
