-- tests/test_log_buffer.lua
-- Pure rolling log ring buffer (fcs/bringup/logbuffer.lua): keeps the last N rows so P-to-dump
-- always uploads a bounded, recent window. No IO.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local LogBuffer = require("fcs.bringup.logbuffer")

t.test("under capacity returns all rows in push order", function()
  local b = LogBuffer.new(3)
  b:push("a"); b:push("b")
  local r = b:rows()
  t.eq(#r, 2); t.eq(r[1], "a"); t.eq(r[2], "b")
  t.eq(b:count(), 2)
end)

t.test("over capacity keeps only the last N rows, oldest-to-newest", function()
  local b = LogBuffer.new(3)
  for i = 1, 5 do b:push("r" .. i) end
  local r = b:rows()
  t.eq(#r, 3, "capped at N")
  t.eq(r[1], "r3"); t.eq(r[2], "r4"); t.eq(r[3], "r5")
  t.eq(b:count(), 3)
end)

t.test("keeps rolling after a dump -- rows() is a snapshot, push continues", function()
  local b = LogBuffer.new(2)
  b:push("a"); b:push("b")
  local snap = b:rows()
  b:push("c")               -- rolls: drops "a"
  t.eq(#snap, 2); t.eq(snap[1], "a")     -- earlier snapshot unaffected
  t.eq(b:rows()[1], "b"); t.eq(b:rows()[2], "c")
end)

return true
