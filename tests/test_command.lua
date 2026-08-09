-- tests/test_command.lua
local t = require("tests.framework")
local command = require("fcs.comms.command")

t.test("sender assigns unique ids and tracks pending", function()
  local s = command.Sender.new({ timeout = 1.0 })
  local f1 = s:send({ k = "engage" })
  local f2 = s:send({ k = "disengage" })
  t.eq(f1.k, "cmd"); t.eq(f1.cmd.k, "engage")
  t.truthy(f1.id ~= f2.id, "unique ids")
end)

t.test("sender retries only after timeout, stops after ack", function()
  local s = command.Sender.new({ timeout = 1.0 })
  local f = s:send({ k = "engage" })
  t.eq(#s:tick(0.5), 0, "no retry before timeout")
  local due = s:tick(0.6)               -- cumulative 1.1 > 1.0
  t.eq(#due, 1, "one retry due"); t.eq(due[1].id, f.id)
  s:ack(f.id)
  t.eq(#s:tick(2.0), 0, "no retry after ack")
end)

t.test("receiver applies once per id and always acks", function()
  local r = command.Receiver.new()
  local applied = 0
  local apply = function(cmd) applied = applied + 1; return true end
  local frame = { k = "cmd", id = 5, cmd = { k = "engage" } }
  local a1 = r:receive(frame, apply)
  local a2 = r:receive(frame, apply)   -- duplicate
  t.eq(applied, 1, "applied once")
  t.eq(a1.k, "ack"); t.eq(a1.id, 5)
  t.eq(a2.id, 5, "still acks duplicate")
end)

t.test("receiver ignores non-command frames", function()
  local r = command.Receiver.new()
  t.eq(r:receive({ k = "tel", seq = 1 }, function() end), nil)
end)

t.test("receiver dedups PER SESSION so a restarted sender (ids reset to 1) is not swallowed", function()
  -- The bug: FCS runs continuously and remembers handled ids; a UI reboot resets the sender to
  -- id 1, which collided with the FCS's old handled set -> the command was acked but never applied.
  local r = command.Receiver.new()
  local applied = 0
  local apply = function() applied = applied + 1 end
  r:receive({ k = "cmd", sid = "A", id = 1, cmd = { k = "engage" } }, apply)
  r:receive({ k = "cmd", sid = "A", id = 1, cmd = { k = "engage" } }, apply)  -- retry within session A
  t.eq(applied, 1, "session A id 1 applied once (retry deduped)")
  r:receive({ k = "cmd", sid = "B", id = 1, cmd = { k = "engage" } }, apply)  -- restarted UI, fresh session
  t.eq(applied, 2, "session B id 1 must NOT be swallowed by session A's id 1")
end)

t.test("sender stamps a session id; ack from another session is ignored", function()
  local s = command.Sender.new({ timeout = 1.0, sid = "S1" })
  local f = s:send({ k = "engage" })
  t.eq(f.sid, "S1", "frame carries the session id")
  s:ack({ k = "ack", sid = "OTHER", id = f.id })   -- stale ack from a previous session
  t.eq(#s:tick(2.0), 1, "wrong-session ack ignored, still pending/retried")
  s:ack({ k = "ack", sid = "S1", id = f.id })       -- our ack
  t.eq(#s:tick(2.0), 0, "our-session ack clears it")
end)
