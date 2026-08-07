-- tests/test_health.lua
local t = require("tests.framework")
local health = require("fcs.comms.health")

t.test("tx beats at most once per period", function()
  local tx = health.Tx.new({ period = 1.0 })
  t.truthy(tx:beat(0.0), "first beat")
  t.eq(tx:beat(0.5), nil, "too soon")
  t.truthy(tx:beat(1.0), "beat after period")
end)

t.test("rx reports up within timeout, down after", function()
  local rx = health.Rx.new({ timeout = 2.0 })
  t.eq(rx:up(0.0), false, "no beat yet -> down")
  rx:mark(1.0)
  t.truthy(rx:up(2.5), "within timeout -> up")
  t.eq(rx:up(3.5), false, "beyond timeout -> down")
end)
