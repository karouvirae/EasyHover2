local t = require("tests.framework")
local Profile = require("fcs.bringup.profile")
local function P(over)
  local c = { baseAlt=0, climbHeight=5, climbRate=1, holdTime=2, descendRate=1,
              landEps=0.4, watchdog=100, overshootMargin=2 }
  if over then for k,v in pairs(over) do c[k]=v end end
  return Profile.new(c)
end

t.test("IDLE holds baseAlt and is inactive", function()
  local r = P():update(1, 0, false)
  t.eq(r.phase,"IDLE"); t.near(r.targetAlt,0,1e-9); t.eq(r.active,false); t.eq(r.done,false)
end)
t.test("begin enters CLIMB and ramps the setpoint at climbRate", function()
  local p = P(); p:begin(); local r = p:update(1, 0, false)
  t.eq(r.phase,"CLIMB"); t.near(r.targetAlt,1,1e-9); t.eq(r.active,true)
end)
t.test("CLIMB caps at top then transitions to HOLD", function()
  local p = P(); p:begin(); p:update(3, 1, false)
  local r = p:update(3, 3, false)     -- target 3 -> capped 5, reaches top -> HOLD
  t.near(r.targetAlt,5,1e-9); t.eq(r.phase,"HOLD")
end)
t.test("HOLD stays at top for holdTime then DESCEND", function()
  local p = P(); p:begin(); p:update(5, 5, false)   -- into HOLD
  t.eq(p.phase,"HOLD")
  local r = p:update(2, 5, false)                    -- held 2 >= 2 -> DESCEND
  t.eq(r.phase,"DESCEND")
end)
t.test("DESCEND lands on onGround", function()
  local p = P(); p:begin(); p:update(5,5,false); p:update(2,5,false)
  local r = p:update(1, 4, true)
  t.eq(r.phase,"LANDED"); t.eq(r.done,true); t.eq(r.active,false)
end)
t.test("DESCEND lands when altitude within landEps of baseAlt", function()
  local p = P(); p:begin(); p:update(5,5,false); p:update(2,5,false)
  local r = p:update(1, 0.3, false)   -- 0.3 <= 0 + 0.4
  t.eq(r.phase,"LANDED"); t.eq(r.done,true)
end)
t.test("abort from CLIMB forces DESCEND", function()
  local p = P(); p:begin(); p:update(1,1,false); p:abort()
  t.eq(p:update(0.1, 1, false).phase, "DESCEND")
end)
t.test("watchdog forces DESCEND after timeout", function()
  local p = P({watchdog=3}); p:begin(); p:update(2, 2, false)
  t.eq(p:update(2, 4, false).phase, "DESCEND")   -- elapsed 4 >= 3
end)
t.test("overshoot forces DESCEND", function()
  local p = P(); p:begin()
  t.eq(p:update(1, 8, false).phase, "DESCEND")   -- alt 8 > top 5 + margin 2
end)
t.test("LANDED stays landed and inactive", function()
  local p = P(); p:begin(); p:update(5,5,false); p:update(2,5,false); p:update(1,0,true)
  local r = p:update(1, 0, true)
  t.eq(r.phase,"LANDED"); t.eq(r.active,false); t.eq(r.done,true)
end)
