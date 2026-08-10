-- tests/test_cfgsync.lua
local t = require("tests.framework")
local S = require("fcs.comms.cfgsync")

t.test("responder answers req with cfg only when the provider has it", function()
  local reply = S.Responder.decide(S.req("x", "tuning"), function(k) return k=="tuning" and "BODY" or nil end)
  t.eq(reply.k, "cfg"); t.eq(reply.kind, "tuning"); t.eq(reply.body, "BODY"); t.eq(reply.sid, "x")
  t.eq(S.Responder.decide(S.req("x","senscal"), function() return nil end), nil, "no body -> no reply")
end)

t.test("client walks hello -> req per kind -> done", function()
  local c = S.Client.new({ sid = "s1", kinds = { "tuning" }, timeout = 1 })
  t.eq(c:next().k, "hello"); t.eq(c:next().k, "cfg" and "req" or "req")  -- first req
  t.eq(c:onFrame(S.cfg("s1", "tuning", "B")), "done"); t.eq(c.received.tuning, "B")
end)
