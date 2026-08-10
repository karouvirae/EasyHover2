local t = require("tests.framework")
local L = require("fcs.boot.loader")
local C = require("fcs.io.cfgspec")

t.test("resolve assembles hw + tuning from chosen valid sources", function()
  local src = { get = function(concern, s)
    if concern == "binding" then return C.defaults("devbind") end
    if concern == "sensor" then return C.defaults("senscal") end
    if concern == "tuning" then return C.defaults("tuning") end
  end }
  local ok, out = L.resolve({ binding="own", sensor="own", tuning="defaults" }, src)
  t.eq(ok, true); t.truthy(out.hw.thrusters and out.hw.bindings and out.tuning.gains)
end)
t.test("resolve fails clearly on a missing/invalid source", function()
  local src = { get = function() return nil end }
  local ok, _, err = L.resolve({ binding="ui", sensor="own", tuning="disk" }, src)
  t.eq(ok, false); t.truthy(err)
end)
t.test("resolve reports WHICH concern failed (for per-concern re-pick)", function()
  -- only the sensor source is missing; binding + tuning resolve fine
  local src = { get = function(concern)
    if concern == "sensor" then return nil end
    if concern == "binding" then return C.defaults("devbind") end
    if concern == "tuning" then return C.defaults("tuning") end
  end }
  local ok, _, err, failed = L.resolve({ binding="own", sensor="own", tuning="defaults" }, src)
  t.eq(ok, false); t.eq(failed, "sensor", "the failing concern is returned")
  -- an invalid source string reports its concern too
  local ok2, _, _, failed2 = L.resolve({ binding="bogus", sensor="own", tuning="defaults" }, src)
  t.eq(ok2, false); t.eq(failed2, "binding")
end)
