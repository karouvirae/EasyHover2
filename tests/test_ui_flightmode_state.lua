-- tests/test_ui_flightmode_state.lua
-- Task 11: flightMode carried from telemetry `latest` through M.buildState into UI state, and
-- folded into cadence.M.sig so the selector repaints when the reported mode changes.
--
-- M.buildState's real signature is M.buildState(runtime, now) -- it reads
-- runtime.rx:latest() internally (see tests/test_basalt_app.lua's own buildState test for the
-- established pattern), so this test drives it the same way: build a runtime via M.buildRuntime,
-- route a telemetry frame carrying flightMode into rx, then assert it lands in the built state.
local t = require("tests.framework")
local app = require("ui.basalt.app")
local cadence = require("ui.basalt.cadence")
local protocol = require("fcs.comms.protocol")
local telemetry = require("fcs.comms.telemetry")

t.test("buildState carries flightMode from telemetry", function()
  local runtime = app.buildRuntime({
    modem = { open = function() end, isWireless = function() return false end,
              transmit = function() end },
    wrap = function() return {} end,
    read = function() return nil end,
  })
  local tx = telemetry.Tx.new()
  local frame = tx:frame({ flightMode = "MAN", mode = "NORMAL" })
  app.routeModem(runtime, app.CH.telemetry, protocol.encode(frame))

  local st = app.buildState(runtime, os.epoch("utc"))
  t.eq(st.flightMode, "MAN", "flightMode copied into state")
end)

t.test("cadence.sig changes when the reported flightMode changes", function()
  local a = cadence.sig({ flightMode = "PRECISION", mode = "NORMAL" })
  local b = cadence.sig({ flightMode = "MAN", mode = "NORMAL" })
  t.truthy(a ~= b, "signature reflects mode change")
end)

t.test("buildState carries trimDir from telemetry", function()
  local runtime = app.buildRuntime({
    modem = { open = function() end, isWireless = function() return false end,
              transmit = function() end },
    wrap = function() return {} end,
    read = function() return nil end,
  })
  local tx = telemetry.Tx.new()
  local frame = tx:frame({ flightMode = "CPL", mode = "NORMAL", trimDir = 1 })
  app.routeModem(runtime, app.CH.telemetry, protocol.encode(frame))

  local st = app.buildState(runtime, os.epoch("utc"))
  t.eq(st.trimDir, 1, "trimDir copied into state")
end)

t.test("cadence.sig changes when the reported trimDir changes", function()
  local a = cadence.sig({ flightMode = "CPL", mode = "NORMAL", trimDir = -1 })
  local b = cadence.sig({ flightMode = "CPL", mode = "NORMAL", trimDir = 1 })
  t.truthy(a ~= b, "signature reflects trimDir change")
end)
