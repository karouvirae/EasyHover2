package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local H = require("nav.lib.heading")

-- absolute(relAngle, sign): the NAV computer's own navigation_table has a magnet aiming it at TRUE
-- NORTH, so getRelativeAngle() is already an ABSOLUTE bearing -- modulo the mod's unstated count
-- direction, which `sign` (+1/-1) corrects. Result wrapped to [0, 360).

t.test("absolute() passes a north-referenced angle through, wrapped to [0,360)", function()
  t.eq(H.absolute(47, 1), 47)
  t.eq(H.absolute(0, 1), 0)
  t.eq(H.absolute(370, 1), 10)    -- wraps past 360
  t.eq(H.absolute(-10, 1), 350)   -- wraps a negative angle up
end)

t.test("absolute() applies a -1 sign when the table counts the other way", function()
  t.eq(H.absolute(47, -1), 313)   -- wrap360(-47)
  t.eq(H.absolute(90, -1), 270)
end)

t.test("absolute() defaults the sign to +1", function()
  t.eq(H.absolute(120), 120)
end)

t.test("absolute() returns nil when the navigation table is silent", function()
  t.eq(H.absolute(nil, 1), nil)   -- getRelativeAngle() can return nil (no target / out of range)
  t.eq(H.absolute("x", 1), nil)
end)

t.test("compass() names the 16 points from a bearing", function()
  t.eq(H.compass(0), "N")
  t.eq(H.compass(45), "NE")
  t.eq(H.compass(90), "E")
  t.eq(H.compass(180), "S")
  t.eq(H.compass(270), "W")
  t.eq(H.compass(360), "N")       -- wraps back to N
  t.eq(H.compass(23), "NNE")
end)

t.test("compass() is honest about a missing bearing", function()
  t.eq(H.compass(nil), "--")
end)

-- calibrateSign: the pilot turns the craft a KNOWN direction and we compare two raw navtable
-- readings. Compass bearings increase CLOCKWISE (N->E->S->W = 0->90->180->270), so a clockwise
-- (rightward) turn must make `absolute` increase. Pick the sign that makes it so.

t.test("calibrateSign() makes a clockwise turn read as increasing heading", function()
  t.eq(H.calibrateSign(10, 40, true), 1)    -- raw went UP for a CW turn -> keep +1
  t.eq(H.calibrateSign(40, 10, true), -1)   -- raw went DOWN for a CW turn -> flip to -1
  t.eq(H.calibrateSign(350, 20, true), 1)   -- +30 across the 0/360 seam -> +1
end)

t.test("calibrateSign() inverts when the reference turn was counter-clockwise", function()
  t.eq(H.calibrateSign(10, 40, false), -1)
end)

t.test("calibrateSign() cannot decide without a real turn", function()
  t.eq(H.calibrateSign(30, 30, true), nil)
end)
