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
local Inst      = require("fcs.bringup.instrument")

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

-- ---- Optional flight instrumentation (NO-OP unless launched via `fcslog`) ----
-- `fcslog` sets _G.EH2_FLIGHTLOG before requiring this module; production `fcs`/`flight` do not,
-- so LOGGING stays false and every logging branch below is a single boolean check per cycle.
-- Same 34-column CSV + summary as tools/hover_test.lua, so flight logs compare 1:1 with hover_test.
local LOGGING   = _G.EH2_FLIGHTLOG == true
local LOG_PATH  = "/eh2_flight_log.csv"
local PART_PATH = "/eh2_flight_log.csv.part"
local logSummary, logPart, logT0
local function logStart()
  if not LOGGING then return end
  logSummary = Inst.Summary.new()
  logPart = fs.open(PART_PATH, "w"); logPart.write(Inst.header() .. "\n")
  logT0 = os.epoch("utc")
end
local function logCycle(dt, m)
  if not LOGGING then return end
  local r = flight.lastDiag or {}
  local dem = r.demands or {}
  local sample = {
    t = (os.epoch("utc") - logT0) / 1000, dt = dt,
    phase = flight.engaged and (m.onGround and "ENG-GND" or "ENGAGED") or "IDLE",
    mode = r.mode or flight.flightMode,
    sp_alt = pilot.sp and pilot.sp.altitude or 0,
    alt = m.altitude, vSpeed = m.vSpeed, pitch = m.pitch, roll = m.roll,
    heading = m.heading, yawRate = m.yawRate, swayVel = m.swayVel, surgeVel = m.surgeVel,
    swayPos = m.swayPos, surgePos = m.surgePos, onGround = m.onGround,
    heave = dem.heave, dPitch = dem.pitch, dRoll = dem.roll, dYaw = dem.yaw,
    dSway = dem.sway, dSurge = dem.surge, duties = r.duties,
  }
  logSummary:add(sample)
  logPart.write(Inst.formatRow(sample) .. "\n")
end
local function logFinish()
  if not LOGGING then return end
  loop:arm(false); pcall(function() loop:cycle(0, backend:sensors()) end)   -- stop thrust on exit
  if logPart then logPart.close() end
  local rows = ""
  local pf = fs.open(PART_PATH, "r"); if pf then rows = pf.readAll() or ""; pf.close() end
  local out = fs.open(LOG_PATH, "w")
  out.write(Inst.formatSummary(logSummary:finalize()) .. "\n\n" .. rows); out.close()
  print(""); print(Inst.formatSummary(logSummary:finalize()))
  print("Log: " .. LOG_PATH)
  pcall(function() shell.run("pastebin", "put", LOG_PATH) end)
end

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
  -- Aggregate: no separate main-tank peripheral exists (fuel is per-thruster),
  -- so the main FUEL gauge shows the mean of the available fractions.
  local sum, count = 0, 0
  for _, f in pairs(snap.thrusterFuel) do sum = sum + f; count = count + 1 end
  snap.fuelMain = (count > 0) and (sum / count) or nil
  return snap
end

-- ---- Tasks ----
local lastT = os.epoch("utc")
local function controlTask()
  -- Self-rescheduling zero-timer: fires as fast as possible while still
  -- yielding every iteration (required under parallel.waitForAny, and to
  -- avoid CC:Tweaked's "Too long without yielding" watchdog).
  local timer = os.startTimer(0)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      local now = os.epoch("utc"); local dt = (now - lastT) / 1000; lastT = now
      local meas = backend:sensors()
      shared.snap = fuelInto(flight:step(dt, heldRef.held, meas))
      logCycle(dt, meas)
      timer = os.startTimer(0)
    end
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

if LOGGING then
  print("EH2 FCS -- FLIGHT LOGGING ON. Fly the repro, then Ctrl-T to stop (log auto-saves + pastebins).")
  logStart()
  local ok, err = pcall(parallel.waitForAny, controlTask, inputTask, telemetryTask, commandTask, healthTask)
  logFinish()
  if not ok then print("FCS EXIT: " .. tostring(err)) end
else
  parallel.waitForAny(controlTask, inputTask, telemetryTask, commandTask, healthTask)
end
