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

t.test("row scrolls: heading 90 puts E under the lubber", function()
  local w = 21
  local row = Tape.row(90, w)
  local c = Tape.lubberCol(w)
  t.eq(row:sub(c, c), "E", "E under the lubber at heading 90")
end)
