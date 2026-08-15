package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local BR = require("beacon.runtime")
local gpsproto = require("nav.comms.gpsproto")

-- A fake ender modem that records what it transmits, so the broadcast is testable with no peripheral.
local function fakeModem()
  return { sent = {}, opened = {},
    open = function(self, ch) self.opened[ch] = true end,
    transmit = function(self, ch, reply, msg) self.sent[#self.sent + 1] = { ch = ch, reply = reply, msg = msg } end,
  }
end
-- CC modems are called method-style (modem.transmit(...)) as globals-free wrapped peripherals; our
-- runtime calls modem.transmit(ch, reply, msg), so bind self.
local function modemFor(m)
  return { open = function(ch) m:open(ch) end, transmit = function(ch, reply, msg) m:transmit(ch, reply, msg) end }
end

local function clockAt(v) local c = { v = v }; return c, function() return c.v end end

t.test("a ready beacon broadcasts its encoded frame on its channel and increments seq", function()
  local raw = fakeModem()
  local c, now = clockAt(1000)
  local r = BR.new({ config = { id = "B1", channel = 65000, enabled = true, pos = { x = 5, y = 6, z = 7 } },
                     modem = modemFor(raw), now = now })
  t.truthy(r:broadcast())
  t.eq(#raw.sent, 1)
  t.eq(raw.sent[1].ch, 65000)
  local f = gpsproto.decode(raw.sent[1].msg)
  t.eq(f.id, "B1"); t.eq(f.x, 5); t.eq(f.y, 6); t.eq(f.z, 7); t.eq(f.seq, 1)
  t.truthy(r:broadcast())
  t.eq(gpsproto.decode(raw.sent[2].msg).seq, 2, "seq advances each broadcast")
end)

t.test("an unconfigured or disabled beacon refuses to broadcast", function()
  local raw = fakeModem()
  local r = BR.new({ config = { id = "B1", channel = 65000, enabled = false, pos = { x = 1, y = 2, z = 3 } },
                     modem = modemFor(raw) })
  t.eq(r:broadcast(), false, "disabled -> no broadcast")
  local r2 = BR.new({ config = { id = "B1", channel = 65000, enabled = true, pos = {} }, modem = modemFor(raw) })
  t.eq(r2:broadcast(), false, "no coordinates -> no broadcast")
  t.eq(#raw.sent, 0)
end)

t.test("hearing peers populates the mesh, excluding our own echo", function()
  local c, now = clockAt(1000)
  local r = BR.new({ config = { id = "B1", channel = 65000, pos = { x = 0, y = 0, z = 0 } },
                     modem = modemFor(fakeModem()), now = now })
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "B2", x = 30, y = 0, z = 0 }), 30)
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "B1", x = 0, y = 0, z = 0 }), 0) -- own echo
  local peers = r:peers()
  t.truthy(peers.B2 ~= nil, "heard B2")
  t.eq(peers.B1, nil, "our own id is not a peer")
end)

t.test("constellation grading over self + peers uses nav geometry", function()
  local c, now = clockAt(1000)
  local r = BR.new({ config = { id = "A", channel = 65000, pos = { x = 0, y = 0, z = 0 } },
                     modem = modemFor(fakeModem()), now = now })
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "B", x = 200, y = 2, z = 0 }), 200)
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "C", x = 0, y = 1, z = 200 }), 200)
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "D", x = 60, y = 150, z = 60 }), 180)
  local g = r:constellation()
  t.truthy(g.usable, "self + 3 non-coplanar peers -> a usable 4-host constellation")
  t.eq(g.usableHosts, 4)
end)

t.test("runtime selfCheck flags a typo'd peer from the heard mesh", function()
  local c, now = clockAt(1000)
  local r = BR.new({ config = { id = "A", channel = 65000, pos = { x = 0, y = 0, z = 0 } },
                     modem = modemFor(fakeModem()), now = now })
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "B", x = 0, y = 0, z = 40 }), 12) -- claims 40, measured 12
  local sc = r:selfCheck()
  t.truthy(not sc.ok)
  t.eq(sc.mismatches[1].id, "B")
end)
