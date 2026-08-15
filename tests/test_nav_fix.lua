package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Fix = require("nav.lib.fix")

-- fix.make(pos, meta): assemble the canonical fix record the NAV runtime relays and the UI shows.
-- Record = { x, y, z, age, quality, source, nBeacons } so downstream (Phase 2) can refuse a stale
-- or low-quality fix.

t.test("make() assembles a flat fix record from a position and metadata", function()
  local f = Fix.make({ x = 128, y = 82, z = -344 },
                     { age = 200, source = "gps", nBeacons = 4, quality = 1.0 })
  t.eq(f.x, 128); t.eq(f.y, 82); t.eq(f.z, -344)
  t.eq(f.age, 200)
  t.eq(f.source, "gps")
  t.eq(f.nBeacons, 4)
  t.eq(f.quality, 1.0)
end)

t.test("make() fills sensible defaults when metadata is omitted", function()
  local f = Fix.make({ x = 1, y = 2, z = 3 })
  t.eq(f.age, 0)
  t.eq(f.source, "gps")
  t.eq(f.nBeacons, 0)
  t.eq(f.quality, nil)   -- unknown quality stays nil rather than a fabricated number
end)

t.test("make() refuses to build a fix without a complete position", function()
  t.eq(Fix.make(nil, { source = "gps" }), nil)
  t.eq(Fix.make({ x = 1, y = 2 }, {}), nil)   -- missing z
end)

t.test("make() carries an error estimate when provided", function()
  local f = Fix.make({ x = 1, y = 2, z = 3 }, { errorEst = 12.5 })
  t.eq(f.errorEst, 12.5)
end)

t.test("make() copies the position so later mutation cannot corrupt the fix", function()
  local pos = { x = 5, y = 6, z = 7 }
  local f = Fix.make(pos, {})
  pos.x = 999
  t.eq(f.x, 5)
end)
