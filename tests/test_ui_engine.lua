package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Engine = require("ui.engine")

local function fakeWriter()
  local w = { calls = {}, last = nil }
  w.fn = function(signal) w.calls[#w.calls+1] = signal; w.last = signal; return true end
  return w
end
local CFG = { pulseMs = 250, intervalMs = 1500, invert = false, kickstart = true, masterDefault = false }

t.test("boots blocked -> physical HIGH, logical feeding=false", function()
  local w = fakeWriter(); local e = Engine.new(CFG, w.fn)
  e:tick(0)
  t.eq(w.last, true); t.eq(e:status(0).master, false); t.eq(e:status(0).feeding, false)
end)

t.test("master ON kickstarts a feed pulse (LOW) then blocks (HIGH) after pulseMs", function()
  local w = fakeWriter(); local e = Engine.new(CFG, w.fn)
  e:setMaster(true, 0)
  t.eq(w.last, false); t.eq(e:status(0).feeding, true)
  e:tick(100); t.eq(w.last, false)
  e:tick(250); t.eq(w.last, true)
end)

t.test("feeds again (LOW) after intervalMs", function()
  local w = fakeWriter(); local e = Engine.new(CFG, w.fn)
  e:setMaster(true, 0); e:tick(250)
  e:tick(1000); t.eq(w.last, true)
  e:tick(1750); t.eq(w.last, false)
end)

t.test("invert flips the physical polarity only", function()
  local w = fakeWriter()
  local e = Engine.new({ pulseMs = 250, intervalMs = 1500, invert = true, kickstart = true, masterDefault = false }, w.fn)
  e:tick(0)
  t.eq(w.last, false); t.eq(e:status(0).feeding, false)
end)

t.test("feedNow errors when master off, pulses (LOW) when on", function()
  local w = fakeWriter(); local e = Engine.new(CFG, w.fn)
  local ok = e:feedNow(0); t.eq(ok, false)
  e:setMaster(true, 0)
  local ok2 = e:feedNow(500); t.eq(ok2, true); t.eq(w.last, false)
end)
