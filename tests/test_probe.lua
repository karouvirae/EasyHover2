local t = require("tests.framework")
local probe = require("tools.probe")
t.test("loadBinding returns err on unparseable split and not defaults", function()
  local cfg, err = probe.loadBinding(function(name)
    if name == "eh2_devbind.tbl" then return "not a table" end
    return nil
  end)
  t.eq(cfg, nil)
  t.eq(err, "unparseable")
end)

t.test("bind assigns a thruster role to a peripheral name", function()
  local c = { thrusters = { FL = false }, sensors = {} }
  local out = probe.bind(c, "FL", "thruster_7")
  t.truthy(out.thrusters.FL == "thruster_7")
end)
t.test("bind assigns a sensor role to a peripheral name", function()
  local c = { thrusters = {}, sensors = { gimbal = false } }
  local out = probe.bind(c, "gimbal", "gimbal_sensor_2")
  t.truthy(out.sensors.gimbal == "gimbal_sensor_2")
end)
t.test("bind on an unknown role returns config unchanged (no crash)", function()
  local c = { thrusters = {}, sensors = {} }
  t.truthy(probe.bind(c, "nope", "x") ~= nil)
end)
t.test("bind assigns roles into the devbind subset (thrusters/sensors/fuelRelay only)", function()
  local c = probe.bind({ thrusters = { FL = false }, sensors = { gimbal = false }, fuelRelay = false }, "gimbal", "gimbal_9")
  t.truthy(c.sensors.gimbal == "gimbal_9")
  c = probe.bind(c, "fuelRelay", "relay_1")
  t.truthy(c.fuelRelay == "relay_1")
end)
