local t = require("tests.framework")
local Sim = require("tests.sim")
local function hoverCfg() return { mass = 4, g = 10, fPer = 15, inertia = 2, armX = 1, armZ = 1 } end
t.test("all four lift on climbs; none falls", function()
  local s = Sim.new(hoverCfg())
  for _, id in ipairs(s:liftIds()) do s:setThruster(id, true) end
  s:step(0.1)
  t.truthy(s:sensors().vSpeed > 0)           -- 60N up vs 40N weight => climbs
  local s2 = Sim.new(hoverCfg()); s2:step(0.1)
  t.truthy(s2:sensors().vSpeed < 0)          -- all off => falls
end)
t.test("front pair only pitches nose up", function()
  local s = Sim.new(hoverCfg())
  s:setThruster("FL", true); s:setThruster("FR", true)
  s:step(0.1)
  t.truthy(s:sensors().pitchRate > 0)
end)
t.test("right pair only rolls right-wing-down", function()
  local s = Sim.new(hoverCfg())
  s:setThruster("FR", true); s:setThruster("RR", true)
  s:step(0.1)
  t.truthy(s:sensors().rollRate > 0)
end)
