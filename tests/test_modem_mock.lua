-- tests/test_modem_mock.lua
local t = require("tests.framework")
local mockmodem = require("tests.mocks.modem")
local modem = require("fcs.comms.modem")

t.test("loopback pair delivers transmits across the link", function()
  local a, b = mockmodem.pair()
  local la = modem.wrap(a, { txCh = 1, rxCh = 2 })  -- A sends on 1, listens on 2
  local lb = modem.wrap(b, { txCh = 2, rxCh = 1 })  -- B sends on 2, listens on 1
  la:send({ k = "cmd", id = 1, cmd = { k = "engage" } })
  local msgs = b:inbox()
  t.eq(#msgs, 1, "one message at B")
  local frame = lb:onMessage(msgs[1].channel, msgs[1].message)
  t.eq(frame.cmd.k, "engage", "decoded on B's rx channel")
end)

t.test("onMessage ignores traffic on the wrong channel", function()
  local a, b = mockmodem.pair()
  local lb = modem.wrap(b, { txCh = 2, rxCh = 1 })
  t.eq(lb:onMessage(999, "whatever"), nil, "wrong channel -> nil")
end)
