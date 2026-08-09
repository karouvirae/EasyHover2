-- EasyHover 2 FCS runtime. Parallel tasks over a single-writer snapshot.
-- FCS PC handles ONLY control + input routing + telemetry-send + command-receive.
-- IN-GAME ONLY (real peripherals + CC globals). Not unit-tested; validated in flight.
package.path = "/?.lua;/?/init.lua;" .. package.path

local hwconfig  = require("fcs.io.hwconfig")
local tuning    = require("fcs.tuning")
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
local flight = Flight.new({ loop = loop, pilot = pilot,
  moveEps = tuning.groundIdle and tuning.groundIdle.moveEps })

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
local MAX_ROWS  = 3000   -- bound RAM/disk (~0.5MB); the in-memory summary still covers the whole run
local logSummary, logT0, logRows
-- Buffer rows in RAM; write the file ONCE at Ctrl-T. CC file writes are synchronous + non-yielding,
-- so writing every control cycle (~20/s) stalled the WHOLE FCS computer as the buffer flushed --
-- freezing comms so the UI panel couldn't toggle GND safety (fcslog-specific; plain `fcs` was fine).
-- Nothing that can block belongs on the control loop -- same lesson as the fuel decouple.
local function logStart()
  if not LOGGING then return end
  logSummary = Inst.Summary.new(); logT0 = os.epoch("utc"); logRows = {}
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
  logSummary:add(sample)                                   -- summary always covers the whole flight
  if #logRows < MAX_ROWS then logRows[#logRows + 1] = Inst.formatRow(sample) end  -- RAM only
end
local function logFinish()
  if not LOGGING then return end
  loop:arm(false); pcall(function() loop:cycle(0, backend:sensors()) end)   -- stop thrust on exit
  local summaryText = Inst.formatSummary(logSummary:finalize())
  pcall(function()                                         -- single write, off the flight path
    if fs.exists(LOG_PATH) then fs.delete(LOG_PATH) end    -- reclaim space from a prior run
    if fs.exists(LOG_PATH .. ".part") then fs.delete(LOG_PATH .. ".part") end
    local f = fs.open(LOG_PATH, "w")
    if f then
      f.write(Inst.header() .. "\n" .. table.concat(logRows, "\n") .. "\n\n" .. summaryText .. "\n")
      f.close()
    end
  end)
  print(""); print(summaryText)                            -- ALWAYS visible, even with no disk/uploader
  print(("Log: %s  (%d rows)"):format(LOG_PATH, #logRows))
  if not pcall(function() return shell.run("carbide", "put", LOG_PATH) end) then
    print("(carbide unavailable -- grab " .. LOG_PATH .. " manually)")
  end
end

-- ---- Fuel readback: DECOUPLED from the control loop ----
-- getFuelAmountMb/getFuelCapacityMb are ~50ms mainThread calls. Polling all 4 lift thrusters
-- INLINE every control cycle cost ~390ms/cycle and collapsed the flight loop to ~2Hz (measured:
-- 122 cycles / 55s, ~452ms/cycle even with ZERO thruster writes), while the identical control
-- stack holds ~16.7Hz in tools/hover_test.lua -- which never polls fuel. So fuel now polls in its
-- own 1Hz task, capacity is constant and cached (read once), the reads run concurrently, and the
-- control loop only copies the latest snapshot (fuelState) -- no peripheral calls on the hot path.
local fuelState = { thrusterFuel = {}, fuelMain = nil }
local fuelPeriph, fuelCap = {}, {}
local function pollFuel()
  local tf, reads = {}, {}
  for i, id in ipairs(frame.LIFT) do
    if fuelPeriph[i] == nil then
      local name = config.thrusters and config.thrusters[id]
      fuelPeriph[i] = (name and shim.wrap(name)) or false
    end
    local p = fuelPeriph[i]
    if p and p.getFuelAmountMb and p.getFuelCapacityMb then
      reads[#reads + 1] = function()
        if fuelCap[i] == nil then
          local okc, cap = pcall(p.getFuelCapacityMb)
          fuelCap[i] = (okc and cap) or false   -- capacity is constant: read once
        end
        local oka, amt = pcall(p.getFuelAmountMb)
        local cap = fuelCap[i]
        if oka and amt and cap and cap > 0 then tf[i] = amt / cap end
      end
    end
  end
  if #reads > 0 then
    if parallel and parallel.waitForAll then parallel.waitForAll(table.unpack(reads))
    else for _, fn in ipairs(reads) do fn() end end
  end
  -- Aggregate: no separate main-tank peripheral exists (fuel is per-thruster),
  -- so the main FUEL gauge shows the mean of the available fractions.
  local sum, count = 0, 0
  for _, f in pairs(tf) do sum = sum + f; count = count + 1 end
  fuelState.thrusterFuel = tf
  fuelState.fuelMain = (count > 0) and (sum / count) or nil
end
local function fuelTask()
  while true do pollFuel(); sleep(1.0) end
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
      local snap = flight:step(dt, heldRef.held, meas)
      snap.thrusterFuel = fuelState.thrusterFuel   -- cheap copy; fuelTask does the peripheral reads
      snap.fuelMain = fuelState.fuelMain
      shared.snap = snap
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
  print("EH2 FCS -- FLIGHT LOGGING ON. Fly the repro, then Ctrl-T to stop (log auto-saves + uploads to carbide).")
  logStart()
  local ok, err = pcall(parallel.waitForAny, controlTask, inputTask, telemetryTask, commandTask, healthTask, fuelTask)
  logFinish()
  if not ok then print("FCS EXIT: " .. tostring(err)) end
else
  parallel.waitForAny(controlTask, inputTask, telemetryTask, commandTask, healthTask, fuelTask)
end
