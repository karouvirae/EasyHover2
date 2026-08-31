package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Tape = require("ui.basalt.instruments.tape")

t.test("norm360 wraps into [0,360)", function()
  t.eq(Tape.norm360(0), 0); t.eq(Tape.norm360(360), 0)
  t.eq(Tape.norm360(-10), 350); t.eq(Tape.norm360(725), 5)
end)

t.test("signedDelta is the shortest signed difference", function()
  t.eq(Tape.signedDelta(10, 0), 10)
  t.eq(Tape.signedDelta(350, 0), -10)
  t.eq(Tape.signedDelta(0, 350), 10)
end)

t.test("lubberLabel is the 3-digit rounded heading", function()
  t.eq(Tape.lubberLabel(90), "090")
  t.eq(Tape.lubberLabel(0), "000")
  t.eq(Tape.lubberLabel(359.6), "000")   -- rounds then wraps
end)

t.test("lubberLabel is --- when the heading is unknown (nil)", function()
  t.eq(Tape.lubberLabel(nil), "---", "no bearing -> dashes, not 000")
end)

t.test("row is blank (all spaces) when the heading is unknown (nil)", function()
  local w = 21
  local row = Tape.row(nil, w)
  t.eq(#row, w, "still full width")
  t.eq(row, string.rep(" ", w), "no scale to draw without a heading reference")
end)

t.test("row is exactly w chars", function()
  for _, w in ipairs({ 1, 5, 21, 40 }) do
    t.eq(#Tape.row(0, w), w, "width " .. w)
  end
end)

t.test("row places the cardinal N at the lubber when heading is 0", function()
  local w = 21
  local row = Tape.row(0, w)
  local c = Tape.lubberCol(w)   -- 11
  t.eq(row:sub(c, c), "N", "N sits under the lubber at heading 0")
end)

t.test("row places a tick one cell-step off the lubber", function()
  -- degPerCell 3, tickEvery 10 -> the +10 deg tick sits at round(10/3)=3 cells right of lubber
  local w = 21
  local row = Tape.row(0, w)
  local c = Tape.lubberCol(w)
  t.eq(row:sub(c + 3, c + 3), Tape.CFG.tickCh, "+10 deg tick 3 cells right")
end)

t.test("bugCol places the target bearing bug relative to the lubber (degPerCell steps)", function()
  local w = 21
  local lub = Tape.lubberCol(w)   -- 11
  t.eq(Tape.bugCol(0, 0, w), lub, "target dead ahead sits on the lubber")
  -- target 30 deg to the right of heading -> round(30/3)=10 cells right
  t.eq(Tape.bugCol(30, 0, w), lub + 10)
  t.eq(Tape.bugCol(330, 0, w), lub - 10, "30 deg left")
end)

t.test("bugCol returns nil when the target bearing is off the visible tape", function()
  local w = 21
  t.eq(Tape.bugCol(180, 0, w), nil, "target directly behind -> off-tape")
  t.eq(Tape.bugCol(nil, 0, w), nil); t.eq(Tape.bugCol(90, nil, w), nil)
end)

t.test("row scrolls: heading 90 puts E under the lubber", function()
  local w = 21
  local row = Tape.row(90, w)
  local c = Tape.lubberCol(w)
  t.eq(row:sub(c, c), "E", "E under the lubber at heading 90")
end)

t.test("isOnHeading: within tol (angle-wrapped), exclusive at the bound", function()
  t.eq(Tape.isOnHeading(70, 70, 1.0), true, "exactly on")
  t.eq(Tape.isOnHeading(70.5, 70, 1.0), true, "within 1 deg")
  t.eq(Tape.isOnHeading(71, 70, 1.0), false, "1 deg away is NOT on (exclusive)")
  t.eq(Tape.isOnHeading(359, 1, 3), true, "wraps across 0/360")
  t.eq(Tape.isOnHeading(nil, 70, 1.0), false, "nil is never on heading")
end)
