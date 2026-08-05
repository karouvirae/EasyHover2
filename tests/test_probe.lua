local t = require("tests.framework")
local probe = require("tools.probe")
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
