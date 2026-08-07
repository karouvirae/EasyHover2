-- EasyHover 2 FCS runtime. Parallel tasks over a single-writer snapshot.
-- FCS PC handles ONLY control + input routing + telemetry-send + command-receive.
-- IN-GAME ONLY (real peripherals + CC globals). Not unit-tested; validated in flight.
package.path = "/?.lua;/?/init.lua;" .. package.path

local hwconfig  = require("fcs.io.hwconfig")
local Backend   = require("fcs.io.backend")
local shim      = require("fcs.io.shim")
local frame     = require("fcs.frame")
local hover     = require("tools.hover_test")
local Flight    = require("fcs.runtime.flight")
local keymap    = require("fcs.input.keymap")
local Pilot     = require("fcs.input.pilot")
local inputCfg  = require("fcs.input.config")
local modemlib  = require("fcs.comms.modem")
local telemetry = require("fcs.comms.telemetry")
local command   = require("fcs.comms.command")
local health    = require("fcs.comms.health")

local CH = { telemetry = 101, command = 102, ack = 103, health = 104 }
local CONFIG_PATH = "/eh2_hw_config.tbl"

-- ---- Build the flight-proven control stack (mirror tools/hover_test.lua) ----
local function loadConfig()
  local saved
  if fs.exists(CONFIG_PATH) then
    local f = fs.open(CONFIG_PATH, "r"); saved = textutils.unserialise(f.readAll() or ""); f.close()
  end
  return hwconfig.merge(saved or {}, hwconfig.defaults())
end

local config  = loadConfig()
local backend = Backend.new(shim, config)
local loop    = hover.buildLoop(backend)   -- SINGLE arg; buildLoop reads tuning itself

local pilot  = Pilot.new(inputCfg.default)
local flight = Flight.new({ loop = loop, pilot = pilot })

-- ---- Comms ----
-- FCS RECEIVES commands on 102 and SENDS: telemetry on 101, acks on 103, heartbeat on 104.
local modem = assert(peripheral.find("modem"), "FCS needs a modem")
for _, c in pairs(CH) do modem.open(c) end
local telLink = modemlib.wrap(modem, { txCh = CH.telemetry, rxCh = CH.command })
local cmdLink = modemlib.wrap(modem, { txCh = CH.ack,       rxCh = CH.command })
local hbLink  = modemlib.wrap(modem, { txCh = CH.health,    rxCh = CH.command })
local tx      = telemetry.Tx.new()
local recv    = command.Receiver.new()
local hbTx    = health.Tx.new({ period = 1.0 })

-- ---- Shared single-writer snapshot ----
local shared = { snap = flight:snapshot(nil, backend:sensors()) }
local typewriter = peripheral.find("linked_typewriter")
local heldRef = { held = {} }

local function fuelInto(snap)
  -- Defensive fuel readback: methods may be absent -> nil (non-blocking).
  snap.thrusterFuel = {}
  for i, id in ipairs(frame.LIFT) do
    local name = config.thrusters and config.thrusters[id]
    local p = name and shim.wrap(name)
    if p and p.getFuelAmountMb and p.getFuelCapacityMb then
      local ok1, amt = pcall(p.getFuelAmountMb)
      local ok2, cap = pcall(p.getFuelCapacityMb)
      snap.thrusterFuel[i] = (ok1 and ok2 and cap and cap > 0) and (amt / cap) or nil
    end
  end
  return snap
end

-- ---- Tasks ----
local lastT = os.epoch("utc")
local function controlTask()
  while true do
    local now = os.epoch("utc"); local dt = (now - lastT) / 1000; lastT = now
    local meas = backend:sensors()
    local snap = flight:step(dt, heldRef.held, meas)
    shared.snap = fuelInto(snap)
    -- fire as fast as possible; loop already clamps dt internally.
  end
end

local function inputTask()
  while true do
    if typewriter and typewriter.getPressedKeyCodes then
      heldRef.held = keymap.resolve(keymap.default, typewriter.getPressedKeyCodes() or {})
    end
    sleep(0.05)
  end
end

local function telemetryTask()
  while true do
    telLink:send(tx:frame(shared.snap))     -- low fixed cadence, fire-and-forget
    sleep(0.1)
  end
end

local function commandTask()
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    local frame_ = cmdLink:onMessage(ch, msg)
    if frame_ then
      local ack = recv:receive(frame_, function(cmd) flight:handleCommand(cmd) end)
      if ack then cmdLink:send(ack) end
    end
  end
end

local function healthTask()
  while true do
    local beat = hbTx:beat(os.epoch("utc") / 1000)
    if beat then hbLink:send(beat) end
    sleep(0.25)
  end
end

parallel.waitForAny(controlTask, inputTask, telemetryTask, commandTask, healthTask)
