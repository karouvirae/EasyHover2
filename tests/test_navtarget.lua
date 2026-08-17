-- tests/test_navtarget.lua
-- Pure waypoint-targeting math (ui/navtarget.lua): craft (x,z,heading,baroY) + target (x,y,z) ->
-- compass bearing, horizontal distance, relative steer bearing (L/R), altitude delta. No peripherals.
-- MC convention: +X east, +Z south; compass N=0 E=90 S=180 W=270.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local NT = require("ui.navtarget")

local function near(a, b) return math.abs(a - b) < 1e-6 end

t.test("bearing points N/E/S/W correctly (MC axes)", function()
  local c = { x = 0, z = 0, heading = 0, baroY = 64 }
  t.truthy(near(NT.solve(c, { x = 0,  y = 64, z = -10 }).bearing, 0),   "north = -Z")
  t.truthy(near(NT.solve(c, { x = 10, y = 64, z = 0   }).bearing, 90),  "east = +X")
  t.truthy(near(NT.solve(c, { x = 0,  y = 64, z = 10  }).bearing, 180), "south = +Z")
  t.truthy(near(NT.solve(c, { x = -10,y = 64, z = 0   }).bearing, 270), "west = -X")
end)

t.test("horizontal distance ignores altitude", function()
  local r = NT.solve({ x = 0, z = 0, heading = 0, baroY = 0 }, { x = 3, y = 999, z = 4 })
  t.truthy(near(r.distanceH, 5), "3-4-5")
end)

t.test("relBearing is the signed turn to the target (right positive)", function()
  -- facing north (heading 0), target due east -> turn right +90
  local r = NT.solve({ x = 0, z = 0, heading = 0, baroY = 0 }, { x = 10, y = 0, z = 0 })
  t.truthy(near(r.relBearing, 90), "east while facing north -> +90 (right)")
  -- facing east (heading 90), target due north (bearing 0) -> turn left -90
  local r2 = NT.solve({ x = 0, z = 0, heading = 90, baroY = 0 }, { x = 0, y = 0, z = -10 })
  t.truthy(near(r2.relBearing, -90), "north while facing east -> -90 (left)")
end)

t.test("altDelta = target.y - craft baro y", function()
  local r = NT.solve({ x = 0, z = 0, heading = 0, baroY = 64 }, { x = 1, y = 100, z = 0 })
  t.truthy(near(r.altDelta, 36))
  local r2 = NT.solve({ x = 0, z = 0, heading = 0, baroY = 80 }, { x = 1, y = 60, z = 0 })
  t.truthy(near(r2.altDelta, -20))
end)

t.test("relBearing/altDelta are nil when heading/baro are unknown, but bearing/dist still compute", function()
  local r = NT.solve({ x = 0, z = 0 }, { x = 10, y = 5, z = 0 })
  t.truthy(near(r.bearing, 90) and near(r.distanceH, 10))
  t.eq(r.relBearing, nil); t.eq(r.altDelta, nil)
end)

t.test("nil / incomplete inputs return nil, no crash", function()
  t.eq(NT.solve(nil, { x = 1, y = 1, z = 1 }), nil)
  t.eq(NT.solve({ x = 0, z = 0 }, nil), nil)
  t.eq(NT.solve({ x = 0 }, { x = 1, y = 1, z = 1 }), nil, "craft missing z -> nil")
end)

return true
