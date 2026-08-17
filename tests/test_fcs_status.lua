-- tests/test_fcs_status.lua
-- Pure FCS console-status view-model (fcs/bringup/status.lua): phase transitions, spinner frames,
-- and the rendered status/logging lines. No peripherals/term.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local status = require("fcs.bringup.status")

t.test("phase: engaged reads RUNNING even during warm-up", function()
  t.eq(status.phase({ elapsedMs = 100, warmupMs = 20000, engaged = true }), "RUNNING")
end)

t.test("phase: WARMUP before warmupMs, IDLE after (while disengaged)", function()
  t.eq(status.phase({ elapsedMs = 5000,  warmupMs = 20000, engaged = false }), "WARMUP")
  t.eq(status.phase({ elapsedMs = 25000, warmupMs = 20000, engaged = false }), "IDLE")
end)

t.test("phase: nil elapsed (loop not ticking yet) is LOADING", function()
  t.eq(status.phase({ warmupMs = 20000, engaged = false }), "LOADING")
end)

t.test("spinner advances by tick, wraps, single char", function()
  t.eq(#status.spinner(0, "idle"), 1)
  t.truthy(status.spinner(0, "idle") ~= status.spinner(1, "idle"), "advances")
  t.eq(status.spinner(0, "idle"), status.spinner(#status.SPIN_IDLE, "idle"), "wraps at frame count")
end)

t.test("idle and running use distinct spinner frame sets", function()
  local same = (#status.SPIN_IDLE == #status.SPIN_RUN)
  if same then
    for i = 1, #status.SPIN_IDLE do same = same and (status.SPIN_IDLE[i] == status.SPIN_RUN[i]) end
  end
  t.truthy(not same, "the two spinner sets differ")
end)

t.test("statusLine: LOADING/WARMUP end in ..., IDLE/RUNNING carry the spinner", function()
  t.eq(status.statusLine("LOADING", "x"), "FCS LOADING...")
  t.eq(status.statusLine("WARMUP",  "x"), "FCS WARM UP...")
  t.eq(status.statusLine("IDLE",    "|"), "FCS IDLE: |")
  t.eq(status.statusLine("RUNNING", "^"), "FCS RUNNING: ^")
end)

t.test("logLine shows the logging state + P hint only when logging is on", function()
  local on = status.logLine(true)
  t.truthy(on:find("LOGGING: ON", 1, true), "shows LOGGING: ON")
  t.truthy(on:find("P to log", 1, true), "shows the P hint")
  t.eq(status.logLine(false), "", "blank when not logging")
end)

return true
