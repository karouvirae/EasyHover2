-- tests/test_cfgserver.lua
local t = require("tests.framework")
local Srv = require("ui.cfgserver")
local S = require("fcs.comms.cfgsync")

t.test("server answers only when running and only for held configs", function()
  local files = { ["/eh2_tuning.tbl"] = "BODY" }
  local s = Srv.new({ dir = "/", read = function(p) return files[p] end })
  t.eq(s:onMessage(S.req("z","tuning")), nil, "stopped -> silent")
  s:start(); local r = s:onMessage(S.req("z","tuning")); t.eq(r.body, "BODY")
  t.eq(s:onMessage(S.req("z","senscal")), nil, "not held -> silent")
  s:onMessage(S.hello("z")); t.truthy(s:status().lastSeen, "hello updates lastSeen")
end)
