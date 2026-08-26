-- tests/test_fcslink.lua
-- Pure staleness/blink decision for the FLIGHT feedback buttons (ui/basalt/fcslink.lua):
-- quick recognition when the FCS was never seen since boot, a grace window when a live link drops.
local t = require("tests.framework")
local F = require("ui.basalt.fcslink")

t.test("never-seen FCS: NOT stale within the boot grace, stale after it (quick startup cue)", function()
  -- UI booted at t=0, no heartbeat has ever arrived (lastSeenMs = nil).
  t.eq((F.evaluate(1000, { bootAt = 0, lastSeenMs = nil })), false, "1000ms < 1500 boot grace -> not yet")
  t.eq((F.evaluate(1600, { bootAt = 0, lastSeenMs = nil })), true, "1600ms > 1500 -> quick cue")
end)

t.test("connected then lost: NOT stale within the drop grace, stale after (tolerates lag)", function()
  local s = { bootAt = 0, lastSeenMs = 1000 }   -- last heartbeat at t=1000ms
  t.eq((F.evaluate(4000, s)), false, "3000ms since last beat < 4000 drop grace -> tolerated")
  t.eq((F.evaluate(5100, s)), true, "4100ms since last beat > 4000 -> cue")
end)

t.test("fresh heartbeat: never stale", function()
  t.eq((F.evaluate(10000, { bootAt = 0, lastSeenMs = 9800 })), false, "200ms ago -> fresh")
end)

t.test("blink phase toggles every BLINK_HALF_MS (500ms)", function()
  local _, p0 = F.evaluate(0,    { lastSeenMs = nil, bootAt = 0 })
  local _, p1 = F.evaluate(500,  { lastSeenMs = nil, bootAt = 0 })
  local _, p2 = F.evaluate(1000, { lastSeenMs = nil, bootAt = 0 })
  t.eq(p0, 0); t.eq(p1, 1); t.eq(p2, 0)
end)

t.test("grace overrides are honored (injectable durations)", function()
  local s = { bootAt = 0, lastSeenMs = nil, bootGraceMs = 100 }
  t.eq((F.evaluate(150, s)), true, "custom 100ms boot grace -> stale at 150ms")
end)
