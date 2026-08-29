-- tests/test_fuelrate.lua
local t = require("tests.framework")
local FuelRate = require("ui.fuelrate")

t.test("fuelrate: <2 samples -> unknown", function()
  local fr = FuelRate.new(); fr:push(10000, 0)
  t.eq(fr:read().state, "unknown", "unknown until 2 samples")
end)

t.test("fuelrate: steady drain -> mbPerMin + secondsLeft", function()
  local fr = FuelRate.new()
  -- 300 mB per 3s = 6000 mB/min; start 12000 mB
  local mb, tm = 12000, 0
  for i = 1, 8 do fr:push(mb, tm); mb = mb - 300; tm = tm + 3000 end
  local r = fr:read()
  t.eq(r.state, "drain", "draining")
  t.near(r.mbPerMin, 6000, 200, "~6000 mB/min")
  t.near(r.secondsLeft, (mb) / (r.mbPerMin/60), 5, "time = mb/rate")   -- mb is current after loop
end)

t.test("fuelrate: step-up snaps toward fast, not stuck on slow", function()
  local fr = FuelRate.new()
  local mb, tm = 20000, 0
  for i = 1, 15 do fr:push(mb, tm); mb = mb - 150; tm = tm + 3000 end   -- slow drain ~3000/min
  local slowRead = fr:read().mbPerMin
  for i = 1, 3 do fr:push(mb, tm); mb = mb - 900; tm = tm + 3000 end    -- sudden hard drain ~18000/min
  local fastRead = fr:read().mbPerMin
  t.truthy(fastRead > slowRead * 2, "snaps up on a big short-term jump")
end)

t.test("fuelrate: rising tank -> refuel", function()
  local fr = FuelRate.new()
  local mb, tm = 5000, 0
  for i = 1, 6 do fr:push(mb, tm); mb = mb + 500; tm = tm + 3000 end
  t.eq(fr:read().state, "refuel", "rising = refuel")
end)

t.test("fuelrate: near-zero drain -> idle", function()
  local fr = FuelRate.new()
  for i = 0, 6 do fr:push(9000, i * 3000) end   -- flat
  t.eq(fr:read().state, "idle", "flat = idle")
end)
