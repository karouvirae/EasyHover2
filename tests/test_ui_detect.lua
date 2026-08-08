package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Detect = require("ui.detect")

t.test("proposes the first relay and first two fuel peripherals", function()
  local p = Detect.propose({
    { name = "monitor_0", type = "monitor", methods = {} },
    { name = "redstone_relay_2", type = "redstone_relay", methods = { setOutput = true } },
    { name = "vault_1", type = "create:item_vault", methods = { list = true, size = true } },
    { name = "tank_3", type = "fluid_tank", methods = { tanks = true } },
  })
  t.eq(p.relay, "redstone_relay_2")
  t.eq(p.fuel.pump, "vault_1")
  t.eq(p.fuel.tank, "tank_3")
end)

t.test("leaves fields nil when nothing matches", function()
  local p = Detect.propose({ { name = "monitor_0", type = "monitor", methods = {} } })
  t.eq(p.relay, nil); t.eq(p.fuel.pump, nil); t.eq(p.fuel.tank, nil)
end)
