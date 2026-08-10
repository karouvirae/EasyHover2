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
