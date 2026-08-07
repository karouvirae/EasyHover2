-- ui/main.lua
-- UI-PC cockpit: receives telemetry, renders reported state, sends commands on touch.
package.path = "/?.lua;/?/init.lua;" .. package.path
local cockpit   = require("ui.cockpit")
local dispatch  = require("ui.dispatch")
local render    = require("ui.render")
local modemlib  = require("fcs.comms.modem")
local telemetry = require("fcs.comms.telemetry")
local command   = require("fcs.comms.command")
local health    = require("fcs.comms.health")

local CH = { telemetry = 101, command = 102, ack = 103, health = 104 }
local mon = peripheral.find("monitor") or term
local modem = peripheral.find("modem")
assert(modem, "UI-PC needs a modem on the wired network")

-- One link per logical channel (UI listens on telemetry/ack/health, sends on command).
local telLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.telemetry })
local ackLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.ack })
local hbLink  = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.health })
for _, c in pairs(CH) do modem.open(c) end

local rx = telemetry.Rx.new()
local sender = command.Sender.new({ timeout = 0.5 })
local hbRx = health.Rx.new({ timeout = 2.0 })
local buttons = cockpit.buttons()

local function snapshot()
  local s = rx:latest() or {}
  s.linkUp = hbRx:up(os.epoch("utc") / 1000)
  return s
end

local function redraw() render.draw(mon, cockpit.render(snapshot()), buttons) end

local function netLoop()
  while true do
    local _, _, ch, reply, msg = os.pullEvent("modem_message")
    local f = telLink:onMessage(ch, msg)
    if f then rx:accept(f)
    else
      local a = ackLink:onMessage(ch, msg); if a and a.k == "ack" then sender:ack(a.id) end
      local h = hbLink:onMessage(ch, msg);  if h and h.k == "hb" then hbRx:mark(os.epoch("utc") / 1000) end
    end
    redraw()
  end
end

local function touchLoop()
  while true do
    local _, _, x, y = os.pullEvent(mon == term and "mouse_click" or "monitor_touch")
    local id = dispatch.resolve(buttons, x, y)
    if id then
      local cmd = cockpit.command(id, snapshot())
      if cmd then telLink:send(sender:send(cmd)) end
    end
  end
end

local function retryLoop()
  while true do
    for _, f in ipairs(sender:tick(0.25)) do telLink:send(f) end
    sleep(0.25)
  end
end

redraw()
parallel.waitForAny(netLoop, touchLoop, retryLoop)
