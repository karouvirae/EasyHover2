package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Runtime = require("nav.runtime")
local gpsproto = require("nav.comms.gpsproto")
local protocol = require("fcs.comms.protocol")

local function clockAt(v) local c = { v = v }; return c, function() return c.v end end

-- A fake modem device (dot-called wrapped-peripheral shape) that records transmits.
local function fakeDev()
  local d = { sent = {} }
  d.open = function(_ch) end
  d.transmit = function(ch, reply, msg) d.sent[#d.sent + 1] = { ch = ch, reply = reply, msg = msg } end
  return d
end

-- Deliver a beacon broadcast to the runtime's GPS receiver, with the CC distance to `target`.
local function hear(rt, ch, beacon, target)
  local dx, dy, dz = target.x - beacon.x, target.y - beacon.y, target.z - beacon.z
  rt:onModemMessage(ch, ch, gpsproto.encode(beacon), math.sqrt(dx * dx + dy * dy + dz * dz))
end

local function newRuntime(now, wired, navtable)
  return Runtime.new({
    config = { channel = 65000, relay = { channel = 107 }, navtable = { name = "nav_0", sign = 1 },
               thresholds = { maxAgeMs = 3000, minQuality = 0.5 } },
    wiredModem = wired, navtable = navtable, now = now,
  })
end

t.test("a 4-beacon stream trilaterates to the known position with a usable quality", function()
  local c, now = clockAt(1000)
  local rt = newRuntime(now, fakeDev(), { getRelativeAngle = function() return 47 end })
  local target = { x = 3, y = 4, z = 5 }
  hear(rt, 65000, { id = "A", x = 0,  y = 0,  z = 0 },  target)
  hear(rt, 65000, { id = "B", x = 20, y = 0,  z = 0 },  target)
  hear(rt, 65000, { id = "C", x = 0,  y = 20, z = 0 },  target)
  hear(rt, 65000, { id = "D", x = 0,  y = 0,  z = 20 }, target)
  local fix = rt:computeFix()
  t.truthy(fix ~= nil, "a fix is produced")
  t.truthy(math.abs(fix.x - 3) < 1e-6 and math.abs(fix.y - 4) < 1e-6 and math.abs(fix.z - 5) < 1e-6)
  t.eq(fix.nBeacons, 4)
  t.eq(fix.source, "gps")
  t.truthy(fix.quality >= 0.5, "usable geometry -> quality above the threshold")
end)

t.test("fewer than 4 beacons yields no fix", function()
  local c, now = clockAt(1000)
  local rt = newRuntime(now, fakeDev(), { getRelativeAngle = function() return 0 end })
  local target = { x = 1, y = 2, z = 3 }
  hear(rt, 65000, { id = "A", x = 0,  y = 0, z = 0 }, target)
  hear(rt, 65000, { id = "B", x = 20, y = 0, z = 0 }, target)
  hear(rt, 65000, { id = "C", x = 0, y = 20, z = 0 }, target)
  t.eq(rt:computeFix(), nil)
end)

t.test("heading reads the NAV computer's own navigation_table, sign-corrected", function()
  local c, now = clockAt(1000)
  local rt = newRuntime(now, fakeDev(), { getRelativeAngle = function() return 47 end })
  t.eq(rt:heading(), 47)
  local rt2 = Runtime.new({ config = { channel = 65000, relay = { channel = 107 },
    navtable = { name = "nav_0", sign = -1 }, thresholds = {} },
    wiredModem = fakeDev(), navtable = { getRelativeAngle = function() return 47 end }, now = now })
  t.eq(rt2:heading(), 313)   -- sign -1 -> wrap360(-47)
end)

t.test("heading survives a silent navigation_table (nil, not a crash)", function()
  local c, now = clockAt(1000)
  local rt = newRuntime(now, fakeDev(), { getRelativeAngle = function() return nil end })
  t.eq(rt:heading(), nil)
end)

t.test("step() relays a nav frame carrying the fix, heading and compass to the craft wire", function()
  local c, now = clockAt(1000)
  local wired = fakeDev()
  local rt = newRuntime(now, wired, { getRelativeAngle = function() return 90 end })
  local target = { x = 3, y = 4, z = 5 }
  hear(rt, 65000, { id = "A", x = 0,  y = 0,  z = 0 },  target)
  hear(rt, 65000, { id = "B", x = 20, y = 0,  z = 0 },  target)
  hear(rt, 65000, { id = "C", x = 0,  y = 20, z = 0 },  target)
  hear(rt, 65000, { id = "D", x = 0,  y = 0,  z = 20 }, target)
  rt:step()
  t.eq(#wired.sent, 1, "one relay frame sent")
  t.eq(wired.sent[1].ch, 107, "on the configured relay channel")
  local frame = protocol.decode(wired.sent[1].msg)
  t.truthy(frame.fix ~= nil and math.abs(frame.fix.x - 3) < 1e-6)
  t.eq(frame.heading, 90)
  t.eq(frame.compass, "E")
end)

t.test("step() still relays heading when there is no fix (NAV alive, position unknown)", function()
  local c, now = clockAt(1000)
  local wired = fakeDev()
  local rt = newRuntime(now, wired, { getRelativeAngle = function() return 180 end })
  rt:step()   -- no beacons heard
  local frame = protocol.decode(wired.sent[1].msg)
  t.eq(frame.fix, nil)
  t.eq(frame.heading, 180)
  t.eq(frame.compass, "S")
end)
