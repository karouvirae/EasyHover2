-- tests/test_routefollow.lua
-- Pure route-following progress (ui/routefollow.lua): pick the active leg (skipping unresolved),
-- detect arrival within the radius, auto-advance to the next leg, clamp at the ends. No peripherals.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local RF = require("ui.routefollow")

-- resolved legs (as nav.waypoints.resolveLegs produces): { wpt, x, z, y, resolved }
local function legs()
  return {
    { wpt = "A", x = 0,   z = 0,   y = 64, resolved = true },
    { wpt = "B", x = 100, z = 0,   y = 70, resolved = true },
    { wpt = "C", x = 200, z = 0,   y = 80, resolved = true },
  }
end

t.test("currentLeg returns the leg at/after i, skipping unresolved", function()
  local L = legs(); L[2].resolved = false; L[2].x = nil; L[2].z = nil
  local leg, k = RF.currentLeg(L, 2)   -- leg 2 unresolved -> skip to 3
  t.eq(k, 3); t.eq(leg.wpt, "C")
  local leg1, k1 = RF.currentLeg(L, 1)
  t.eq(k1, 1); t.eq(leg1.wpt, "A")
end)

t.test("arrived is true only within the radius (horizontal)", function()
  local leg = { x = 100, z = 0, resolved = true }
  t.eq(RF.arrived(leg, { x = 60, z = 0 }, 50), true, "40 blk away, radius 50 -> arrived")
  t.eq(RF.arrived(leg, { x = 40, z = 0 }, 50), false, "60 blk away -> not arrived")
  t.eq(RF.arrived(leg, nil, 50), false)
end)

t.test("step advances to the next leg once arrived, and yields the target", function()
  local L = legs()
  -- sitting on A (within 50) -> should advance to B
  local s = RF.step(L, 1, { x = 10, z = 0 }, 50)
  t.eq(s.i, 2); t.eq(s.target.name, "B"); t.eq(s.target.x, 100); t.eq(s.target.y, 70)
  -- far from B -> stays on B
  local s2 = RF.step(L, 2, { x = 0, z = 0 }, 50)
  t.eq(s2.i, 2); t.eq(s2.target.name, "B")
end)

t.test("step clamps at the final leg (no advance past the end)", function()
  local L = legs()
  local s = RF.step(L, 3, { x = 200, z = 0 }, 50)   -- arrived at C, the last leg
  t.eq(s.i, 3); t.eq(s.target.name, "C"); t.eq(s.atEnd, true)
end)

t.test("step with no resolved legs yields no target, no crash", function()
  local s = RF.step({ { wpt = "X", resolved = false } }, 1, { x = 0, z = 0 }, 50)
  t.eq(s.target, nil)
end)

return true
