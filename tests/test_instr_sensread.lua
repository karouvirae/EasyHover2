package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local S = require("ui.basalt.instruments.sensread")

t.test("attitude applies sign*scale*axis, mirroring backend.lua", function()
  local cal = { signPitch = -1, signRoll = 1, gimbalScale = math.pi/180, gimbalPitchIdx = 2, gimbalRollIdx = 1 }
  local p, r = S.attitude({ 10, 20 }, cal)   -- pitch reads idx2 (20), roll reads idx1 (10)
  t.truthy(math.abs(p - (-1 * (math.pi/180) * 20)) < 1e-9, "pitch")
  t.truthy(math.abs(r - ( 1 * (math.pi/180) * 10)) < 1e-9, "roll")
end)

t.test("attitude defaults are safe (idx 1/2, sign 1, scale 1)", function()
  local p, r = S.attitude({ 3, 7 }, {})
  t.eq(p, 3); t.eq(r, 7)
  local p2, r2 = S.attitude(nil, {})   -- non-table angles
  t.eq(p2, 0); t.eq(r2, 0)
end)

t.test("surge applies signVelMedial", function()
  t.eq(S.surge(4, { signVelMedial = -1 }), -4)
  t.eq(S.surge(nil, {}), 0)
  t.eq(S.surge(5, {}), 5)
end)
