package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Engine = require("ui.engine")

local function fakeWriter()
  local w = { calls = {}, last = nil }
  w.fn = function(on) w.calls[#w.calls + 1] = on; w.last = on; return true end
  return w
end
local CFG = { pulseMs = 250, intervalMs = 1500, invert = false, kickstart = true, masterDefault = false }

t.test("boots blocked (feeding=false) and stays blocked on tick", function()
  local w = fakeWriter()
  local e = Engine.new(CFG, w.fn)
  e:tick(0)
  t.eq(w.last, false)                 -- blocked = not feeding
  t.eq(e:status(0).master, false)
end)

t.test("master ON kickstarts a feed pulse then blocks after pulseMs", function()
  local w = fakeWriter()
  local e = Engine.new(CFG, w.fn)
  e:setMaster(true, 0)
  t.eq(w.last, true)                  -- kickstart feed
  e:tick(100); t.eq(w.last, true)     -- still within pulseMs
  e:tick(250); t.eq(w.last, false)    -- pulse ended -> blocked
end)

t.test("feeds again after intervalMs", function()
  local w = fakeWriter()
  local e = Engine.new(CFG, w.fn)
  e:setMaster(true, 0)
  e:tick(250)                         -- pulse ends at 250, next feed at 250+1500
  e:tick(1000); t.eq(w.last, false)   -- still waiting
  e:tick(1750); t.eq(w.last, true)    -- interval elapsed -> feed
end)

t.test("invert flips the physical polarity only", function()
  local w = fakeWriter()
  local e = Engine.new({ pulseMs = 250, intervalMs = 1500, invert = true, kickstart = true, masterDefault = false }, w.fn)
  e:tick(0)
  t.eq(w.last, true)                  -- blocked, but inverted -> physical true
end)

t.test("feedNow errors when master off, pulses when on", function()
  local w = fakeWriter()
  local e = Engine.new(CFG, w.fn)
  local ok = e:feedNow(0); t.eq(ok, false)
  e:setMaster(true, 0)
  local ok2 = e:feedNow(500); t.eq(ok2, true); t.eq(w.last, true)
end)
