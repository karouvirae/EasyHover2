package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Receiver = require("nav.comms.receiver")
local proto = require("nav.comms.gpsproto")
local Tri = require("nav.lib.trilaterate")

-- A controllable clock so staleness/age are deterministic (no os.epoch in a pure test).
local function clockAt(v) local c = { v = v }; return c, function() return c.v end end

-- Simulate a beacon broadcast arriving as a modem_message: (channel, replyChannel, msg, distance).
local function broadcast(r, ch, beacon, target)
  local dx, dy, dz = target.x - beacon.x, target.y - beacon.y, target.z - beacon.z
  local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
  return r:onMessage(ch, ch, proto.encode(beacon), dist)
end

t.test("onMessage stores a decoded beacon as a usable observation", function()
  local c, now = clockAt(1000)
  local r = Receiver.new({ channel = 65000, now = now })
  t.truthy(r:onMessage(65000, 65000, proto.encode({ id = "B1", x = 0, y = 0, z = 0 }), 12.5))
  local obs = r:observations()
  t.eq(#obs, 1)
  t.eq(obs[1].dist, 12.5)
  t.eq(obs[1].pos.x, 0); t.eq(obs[1].pos.y, 0); t.eq(obs[1].pos.z, 0)
end)

t.test("aggregates 4 beacons into observations that trilaterate to the known position", function()
  local c, now = clockAt(1000)
  local r = Receiver.new({ channel = 65000, now = now })
  local target = { x = 3, y = 4, z = 5 }
  broadcast(r, 65000, { id = "A", x = 0,  y = 0,  z = 0 },  target)
  broadcast(r, 65000, { id = "B", x = 20, y = 0,  z = 0 },  target)
  broadcast(r, 65000, { id = "C", x = 0,  y = 20, z = 0 },  target)
  broadcast(r, 65000, { id = "D", x = 0,  y = 0,  z = 20 }, target)
  local p = Tri.solve(r:observations())
  t.truthy(p ~= nil, "4 fresh beacons -> a fix")
  t.truthy(math.abs(p.x - 3) < 1e-6 and math.abs(p.y - 4) < 1e-6 and math.abs(p.z - 5) < 1e-6,
    "recovers (3,4,5)")
end)

t.test("ignores broadcasts on a different channel", function()
  local c, now = clockAt(1000)
  local r = Receiver.new({ channel = 65000, now = now })
  t.eq(r:onMessage(101, 101, proto.encode({ id = "X", x = 1, y = 2, z = 3 }), 4), false)
  t.eq(#r:observations(), 0)
end)

t.test("drops a stale beacon once it ages past staleMs", function()
  local c, now = clockAt(1000)
  local r = Receiver.new({ channel = 65000, staleMs = 5000, now = now })
  r:onMessage(65000, 65000, proto.encode({ id = "B1", x = 0, y = 0, z = 0 }), 10)
  c.v = 5500   -- 4.5s later: still fresh
  t.eq(#r:observations(), 1)
  c.v = 7000   -- 6s after receipt: stale
  t.eq(#r:observations(), 0)
end)

t.test("latest broadcast wins for the same beacon id (position + distance + age update)", function()
  local c, now = clockAt(1000)
  local r = Receiver.new({ channel = 65000, now = now })
  r:onMessage(65000, 65000, proto.encode({ id = "B1", x = 0, y = 0, z = 0, seq = 1 }), 10)
  c.v = 2000
  r:onMessage(65000, 65000, proto.encode({ id = "B1", x = 0, y = 0, z = 0, seq = 2 }), 8)
  local b = r:beacons()
  t.eq(b.B1.dist, 8)
  t.eq(b.B1.seq, 2)
  t.eq(b.B1.ageMs, 0)   -- just received at now=2000
end)

t.test("a broadcast with no distance is stored but is not a usable observation", function()
  local c, now = clockAt(1000)
  local r = Receiver.new({ channel = 65000, now = now })
  r:onMessage(65000, 65000, proto.encode({ id = "B1", x = 0, y = 0, z = 0 }), nil)
  t.eq(#r:observations(), 0, "no range -> cannot contribute to a fix")
  t.truthy(r:beacons().B1 ~= nil, "but we still heard it (mesh/self-check can use its position)")
end)
