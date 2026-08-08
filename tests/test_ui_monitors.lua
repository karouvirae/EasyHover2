-- tests/test_ui_monitors.lua
local t = require("tests.framework")
local M = require("ui.monitors")

t.test("resolve keeps present assignments, mirrors, lists unassigned", function()
  local assign = { monitor_0 = "engine", monitor_1 = "engine", monitor_2 = "fcs", ghost = "config" }
  local r = M.resolve(assign, { "monitor_0", "monitor_1", "monitor_2", "monitor_3" })
  t.eq(r.assigned.monitor_0, "engine")
  t.eq(r.assigned.monitor_1, "engine")   -- mirrored
  t.eq(r.assigned.monitor_2, "fcs")
  t.eq(r.assigned.ghost, nil)            -- not present -> dropped
  t.eq(#r.unassigned, 1)                 -- monitor_3
  t.eq(r.unassigned[1], "monitor_3")
end)

t.test("route returns the assigned panel or nil", function()
  local assign = { monitor_0 = "engine" }
  t.eq(M.route(assign, "monitor_0"), "engine")
  t.eq(M.route(assign, "monitor_9"), nil)
end)
