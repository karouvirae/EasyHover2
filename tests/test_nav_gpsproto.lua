package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local proto = require("nav.comms.gpsproto")

-- gpsproto: the broadcast GPS frame {id,x,y,z,seq}. Reuses fcs/comms/protocol for serialization but
-- adds GPS-specific validation so the receiver never trilaterates off a malformed broadcast.

t.test("encode/decode round-trips a beacon broadcast frame", function()
  local dec = proto.decode(proto.encode({ id = "B2", x = 128, y = 82, z = -344, seq = 5 }))
  t.eq(dec.id, "B2")
  t.eq(dec.x, 128); t.eq(dec.y, 82); t.eq(dec.z, -344)
  t.eq(dec.seq, 5)
end)

t.test("encode keeps only the GPS fields (a stray field does not survive)", function()
  local dec = proto.decode(proto.encode({ id = 1, x = 0, y = 0, z = 0, seq = 1, junk = "no" }))
  t.eq(dec.junk, nil)
end)

t.test("decode rejects a frame missing coordinates", function()
  t.eq(proto.decode(proto.encode({ id = 1, x = 0, y = 0 })), nil)   -- no z
end)

t.test("decode rejects a frame with no id", function()
  t.eq(proto.decode(proto.encode({ x = 1, y = 2, z = 3 })), nil)
end)

t.test("decode returns nil on garbage instead of throwing", function()
  t.eq(proto.decode("}{ not lua"), nil)
  t.eq(proto.decode(nil), nil)
  t.eq(proto.decode("42"), nil)   -- valid lua, not a frame table
end)
