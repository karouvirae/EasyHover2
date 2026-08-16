package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Tool = require("tools.beaconupdate")
local U = require("beacon.update")

t.test("refuses to broadcast without a valid token", function()
  local sent = {}
  local r = Tool.run({ token = "  ", channel = 65000,
    transmit = function(...) sent[#sent + 1] = { ... } end, pull = function() return nil end })
  t.eq(r.ok, false, "refused")
  t.eq(#sent, 0, "nothing broadcast")
  t.truthy(r.err and #r.err > 0, "explains why")
end)

t.test("broadcasts exactly one command frame carrying the token", function()
  local sent = {}
  Tool.run({ token = "tok", channel = 65000,
    transmit = function(ch, reply, msg) sent[#sent + 1] = { ch = ch, msg = msg } end,
    pull = function() return nil end })
  t.eq(#sent, 1, "one broadcast")
  t.eq(sent[1].ch, 65000)
  local f = U.decode(sent[1].msg)
  t.truthy(f and f.k == U.CMD_KIND and f.token == "tok", "carries the command + token")
end)

t.test("collects and sorts ack ids, ignoring dupes; nil ends the window", function()
  local acks = { "beacon-70", "beacon-67", "beacon-70", nil }  -- nil ends the window
  local i = 0
  local r = Tool.run({ token = "tok", channel = 65000,
    transmit = function() end,
    pull = function()
      i = i + 1
      return acks[i]   -- returns nil at index 4 -> window closes
    end })
  t.eq(r.ok, true)
  t.eq(table.concat(r.responders, ","), "beacon-67,beacon-70", "sorted + de-duped")
end)

t.test("no responders is a clean empty list, not an error", function()
  local r = Tool.run({ token = "tok", channel = 65000, transmit = function() end, pull = function() return nil end })
  t.eq(r.ok, true)
  t.eq(#r.responders, 0)
end)
