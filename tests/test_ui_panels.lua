package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local fcs = require("ui.panels.fcs")

local SNAP = { engaged = false, gndSafety = false, positionHold = false, mode = "GROUND",
               altitude = 12.3, vSpeed = 0.1, heading = 90, loopHz = 15, linkUp = true }

t.test("fcs identity + layout has the five controls", function()
  t.eq(fcs.id, "fcs")
  local lay = fcs.layout(51, 19)
  local ids = {}; for _, b in ipairs(lay.buttons) do ids[b.id] = true end
  for _, id in ipairs({ "engage","disengage","gndSafety","positionHold","clearDamped" }) do
    t.eq(ids[id], true)
  end
end)

t.test("engage command when safe; nil when GND safety on", function()
  t.eq(fcs.action("engage", SNAP).cmd.k, "engage")
  local locked = {}; for k,v in pairs(SNAP) do locked[k]=v end; locked.gndSafety = true
  t.eq(fcs.action("engage", locked), nil)
end)

t.test("toggles compute target from reported state", function()
  t.eq(fcs.action("gndSafety", SNAP).cmd.on, true)      -- off -> request on
  local on = {}; for k,v in pairs(SNAP) do on[k]=v end; on.positionHold = true
  t.eq(fcs.action("positionHold", on).cmd.on, false)    -- on -> request off
  t.eq(fcs.action("clearDamped", SNAP).cmd.k, "clearDamped")
end)

t.test("render reflects reported engage/damped state", function()
  local dl = fcs.render(SNAP)
  local st = {}; for _, item in ipairs(dl) do if item.kind == "button" then st[item.id] = item.state end end
  t.eq(st.gndSafety, "off")
  local damped = {}; for k,v in pairs(SNAP) do damped[k]=v end; damped.mode = "DAMPED"
  local st2 = {}; for _, item in ipairs(fcs.render(damped)) do if item.kind=="button" then st2[item.id]=item.state end end
  t.eq(st2.clearDamped, "active")
end)

t.test("fcs render places buttons within bounds at a smaller size", function()
  local dl = fcs.render(SNAP, 39, 13)
  local n = 0
  for _, item in ipairs(dl) do
    if item.kind == "button" then
      n = n + 1
      local r = item.rect
      t.eq(r.x >= 1 and r.y >= 1 and r.x + r.w - 1 <= 39 and r.y + r.h - 1 <= 13, true)
    end
  end
  t.eq(n >= 5, true)   -- all five controls present and in-bounds
end)
