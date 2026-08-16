package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local A = require("ui.basalt.instruments.attitude")

-- helper: find the first cell with a given char, return {x,y} or nil
local function find(cells, ch)
  for _, c in ipairs(cells) do if c.ch == ch then return c end end
  return nil
end

t.test("pitchRows: level is 0, up is +2, down is -2 (raw magnitude)", function()
  t.eq(A.pitchRows(0), 0)
  t.eq(A.pitchRows(10), 2)     -- 10/5 = 2 (craftCells applies the up=negative sign)
  t.eq(A.pitchRows(-10), -2)
end)

t.test("bankStep clamps to +/- maxStep", function()
  t.eq(A.bankStep(0), 0)
  t.eq(A.bankStep(5), 1)
  t.eq(A.bankStep(90), A.CFG.maxStep, "clamped high")
  t.eq(A.bankStep(-90), -A.CFG.maxStep, "clamped low")
end)

t.test("level flight: circle sits at box center", function()
  local w, h = 21, 11
  local cells = A.craftCells(0, 0, w, h)
  local o = find(cells, A.CFG.circleCh)
  t.truthy(o, "circle present")
  t.eq(o.x, math.ceil(w / 2), "circle centered x")
  t.eq(o.y, math.ceil(h / 2), "circle centered y at level pitch")
end)

t.test("pitch up moves the circle up (smaller y)", function()
  local w, h = 21, 11
  local level = find(A.craftCells(0, 0, w, h), A.CFG.circleCh)
  local up    = find(A.craftCells(20, 0, w, h), A.CFG.circleCh)  -- +20 deg
  t.truthy(up.y < level.y, "pitch up -> circle higher on screen")
end)

t.test("wings present on both sides at level; tips are tipCh", function()
  local w, h = 21, 11
  local cells = A.craftCells(0, 0, w, h)
  local tips = 0
  for _, c in ipairs(cells) do if c.ch == A.CFG.tipCh then tips = tips + 1 end end
  t.truthy(tips >= 2, "at least a left and right tip")
end)

t.test("bank right lowers the right tip relative to the left tip", function()
  local w, h = 25, 13
  local cells = A.craftCells(0, 30, w, h)   -- strong right bank
  local o = find(cells, A.CFG.circleCh)
  local leftTip, rightTip
  for _, c in ipairs(cells) do
    if c.ch == A.CFG.tipCh then
      if c.x < o.x then leftTip = c elseif c.x > o.x then rightTip = c end
    end
  end
  t.truthy(leftTip and rightTip, "both tips present")
  t.truthy(rightTip.y > leftTip.y, "right tip lower (larger y) under right bank")
end)

t.test("all returned cells are inside the box", function()
  local w, h = 15, 9
  for _, c in ipairs(A.craftCells(40, 45, w, h)) do  -- extreme attitude, must still clip
    t.truthy(c.x >= 1 and c.x <= w and c.y >= 1 and c.y <= h, "cell in bounds")
  end
end)
