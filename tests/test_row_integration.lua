-- tests/test_row_integration.lua
local t         = require("tests.framework")
local Flight    = require("fcs.runtime.flight")
local Pilot     = require("fcs.input.pilot")
local mockmodem = require("tests.mocks.modem")
local modemlib  = require("fcs.comms.modem")
local telemetry = require("fcs.comms.telemetry")
local command   = require("fcs.comms.command")
local cockpit   = require("ui.cockpit")
local dispatch  = require("ui.dispatch")

local function fakeLoop()
  local L = { armed=false, sp=nil, mode="NORMAL" }
  function L:arm(b) self.armed = b and true or false end
  function L:setpoints(x) self.sp = x end
  function L:clearDamped() self.mode = "NORMAL" end
  function L:getMode() return self.mode end
  function L:cycle(_, m) return { mode = self.mode, m = m } end
  return L
end
local CFG = { headingRate=0.6, climbRate=0.8, leadCapVert=3, cruiseSpeed=1, maxLead=4 }
local function meas() return { altitude=10, heading=0, swayPos=0, surgePos=0,
  vSpeed=0, yawRate=0, swayVel=0, surgeVel=0, pitch=0, roll=0, onGround=false } end

t.test("UI touch -> command -> FCS engage-gate -> telemetry -> panel round-trip", function()
  -- Wire a loopback link: FCS listens on command ch, sends telemetry/ack back.
  local fcsDev, uiDev = mockmodem.pair()
  local CH = { tel = 101, cmd = 102, ack = 103 }
  local fcsCmd = modemlib.wrap(fcsDev, { txCh = CH.ack, rxCh = CH.cmd })
  local fcsTel = modemlib.wrap(fcsDev, { txCh = CH.tel, rxCh = CH.cmd })
  local uiCmd  = modemlib.wrap(uiDev,  { txCh = CH.cmd, rxCh = CH.ack })
  local uiTel  = modemlib.wrap(uiDev,  { txCh = CH.cmd, rxCh = CH.tel })

  local flight = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  local recv   = command.Receiver.new()
  local tx     = telemetry.Tx.new()
  local rx     = telemetry.Rx.new()
  local sender = command.Sender.new({ timeout = 1.0 })

  -- 1. UI resolves a touch on GND-SAFE and sends the toggle command.
  local buttons = cockpit.buttons()
  local gnd
  for _, b in ipairs(buttons) do if b.id == "gndSafety" then gnd = b end end
  local uiSnap = { gndSafety = true }  -- reported: safety on
  local id = dispatch.resolve(buttons, gnd.rect.x + 1, gnd.rect.y + 1)
  uiCmd:send(sender:send(cockpit.command(id, uiSnap)))   -- request gndSafety off

  -- 2. FCS receives the command, applies it, acks.
  local msg = fcsDev:inbox()[1]
  local frame = fcsCmd:onMessage(msg.channel, msg.message)
  local ack = recv:receive(frame, function(cmd) flight:handleCommand(cmd) end)
  fcsCmd:send(ack)
  t.eq(flight.gndSafety, false, "FCS applied gndSafety off")

  -- 3. UI receives the ack, clears the pending retry.
  local am = uiDev:inbox()[1]
  local af = uiCmd:onMessage(am.channel, am.message)
  t.eq(af.k, "ack"); sender:ack(af.id)
  t.eq(#sender:tick(2.0), 0, "no retries pending after ack")

  -- 4. FCS steps and publishes telemetry; UI accepts and renders reported state.
  local snap = flight:step(0.1, {}, meas())
  fcsTel:send(tx:frame(snap))
  local tm = uiDev:inbox()[1]
  local tf = uiTel:onMessage(tm.channel, tm.message)
  t.truthy(rx:accept(tf), "UI accepted telemetry")
  local model = cockpit.render(rx:latest())
  t.eq(model.buttons.gndSafety, "off", "panel reflects reported gndSafety off")
end)
