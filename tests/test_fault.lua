local t = require("tests.framework")
local fault = require("fcs.runtime.fault")

t.test("orReraise: Terminated is re-raised so parallel.waitForAny can unwind", function()
  local ok, err = pcall(function() fault.orReraise("Terminated") end)
  t.eq(ok, false)
  t.eq(err, "Terminated")
end)

t.test("orReraise: other errors become strings for the console, not re-raised", function()
  t.eq(fault.orReraise("sensor boom"), "sensor boom")
  t.eq(fault.orReraise(false), "false")
end)
