-- tests/test_protocol.lua
local t = require("tests.framework")
local protocol = require("fcs.comms.protocol")

t.test("encode/decode round-trips a table frame", function()
  local f = { k = "cmd", id = 7, cmd = { k = "engage" } }
  local dec = protocol.decode(protocol.encode(f))
  t.eq(dec.k, "cmd"); t.eq(dec.id, 7); t.eq(dec.cmd.k, "engage")
end)

t.test("decode returns nil on garbage instead of throwing", function()
  t.eq(protocol.decode("}{ not lua"), nil, "garbage -> nil")
  t.eq(protocol.decode(nil), nil, "nil -> nil")
  t.eq(protocol.decode(123), nil, "number -> nil")
  t.eq(protocol.decode("42"), nil, "non-table -> nil")
end)
