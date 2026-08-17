-- fcs/boot/loaderui.lua
-- Terminal boot UI: lets the pilot pick a SOURCE per config concern (binding/sensor/tuning),
-- assembles the runtime config via fcs.boot.loader, and writes the two files the flight app
-- already reads (/eh2_hw_config.tbl + /eh2_tuning.tbl) -- the whole handoff. Boot UI and the
-- flight app never run concurrently: this program returns (or the launcher exits) before
-- launchers/flight.lua starts. No Basalt here on purpose -- keeps the FCS boot path light and
-- dependency-free.
--
-- CHANNEL CONVENTION (Task 10's UI cfgserver responder mirrors this):
--   CFG_CH = { req = 105, reply = 106 }
--   The boot UI (cfgsync client, here) SENDS requests on req (105) and LISTENS for replies on
--   reply (106). The UI-side responder does the opposite: listens on req, replies on reply.
--   Channels 101-104 (telemetry/command/ack/health, see tools/flight.lua) are NOT reused.
--
-- CRITICAL: no peripheral/modem/disk access at module load time -- headless has no modem/disk,
-- so `require("fcs.boot.loaderui")` must load clean. All peripheral access lives inside
-- run()/buildSources() (and the real read/write helpers they call), never at the top level.

local loader         = require("fcs.boot.loader")
local cfgspec         = require("fcs.io.cfgspec")
local tuningdefaults  = require("fcs.io.tuningdefaults")
local cfgsync         = require("fcs.comms.cfgsync")
local modemlib        = require("fcs.comms.modem")
local fsx             = require("fcs.io.fsx")

local M = {}

M.CFG_CH = { req = 105, reply = 106 }

local HW_CONFIG_PATH  = "/eh2_hw_config.tbl"
local TUNING_PATH     = "/eh2_tuning.tbl"
local LEGACY_CONFIG_PATH = HW_CONFIG_PATH -- same file; legacy read-through source, not the write target

-- concern name -> cfgspec kind (mirrors fcs/boot/loader.lua's KIND table)
local KIND = { binding = "devbind", sensor = "senscal", tuning = "tuning" }

local UI_TIMEOUT = 2.0  -- seconds per attempt
local UI_RETRIES = 3

-- =====================================================================================
-- Testable seam (headless) -- pure given injected write(); no read()/fs/peripheral here.
-- =====================================================================================

local realWrite = fsx.writeAtomic

-- Atomically write the assembled hw + tuning tables to the two files the flight app reads.
-- `write(path, body)` is injected for testing; defaults to the real atomic tmp-then-move writer.
function M.commit(assembled, write)
  write = write or realWrite
  write(HW_CONFIG_PATH, textutils.serialise(assembled.hw))
  write(TUNING_PATH, textutils.serialise(assembled.tuning))
  return true
end

-- Resolve the pilot's chosen sources into an assembled config, then commit it.
-- Returns true, assembled  on success, or  false, nil, err  (nothing is written on failure).
function M.finish(choices, sources, write)
  local ok, assembled, err, failedConcern = loader.resolve(choices, sources)
  if not ok then return false, nil, err, failedConcern end
  M.commit(assembled, write)
  return true, assembled
end

-- True for sources that come from OUTSIDE this computer's own filesystem ("disk"/"ui") --
-- these overwrite the FCS runtime config from an external source, so the in-game pick flow
-- confirms with the pilot before proceeding. "own"/"defaults" are local/inert and proceed
-- silently. Pure: no fs/peripheral/read() -- safe to unit test headless.
function M.needsConfirm(src) return src == "disk" or src == "ui" end

-- =====================================================================================
-- In-game only from here down: real fs/peripheral/modem/read() access. NOT headless-tested
-- (no modem/disk in the CraftOS-PC harness); kept coherent by reading, mirrored against the
-- design doc's "Own / Request from UI PC / Load from disk / Load defaults" flow.
-- =====================================================================================

local realRead = fsx.read

-- "own": the local split file (eh2_devbind.tbl / eh2_senscal.tbl); if that file is ABSENT and
-- the legacy combined /eh2_hw_config.tbl exists, seed from splitLegacy read-through (mirrors
-- tools/calibrate.lua's M._loadCal / loadSensors so terminal tool and boot UI agree).
local function ownSource(concern)
  local kind = KIND[concern]
  local cfg, existed, err = cfgspec.load(kind, realRead)
  -- Present-but-unparseable local file: treat as UNAVAILABLE (nil) rather than silently
  -- flying with cfgspec's defaults. resolve then fails on this concern so the pilot must
  -- re-pick (the source menu shows "split file CORRUPT" so they know why).
  if err then return nil end
  if existed then return cfg end
  local legacyBody = realRead(LEGACY_CONFIG_PATH)
  if legacyBody == nil then return nil end
  local legacy = textutils.unserialise(legacyBody)
  if type(legacy) ~= "table" then return nil end
  local split = cfgspec.splitLegacy(legacy)
  local seed = split[kind]
  if seed == nil then return nil end
  return cfgspec.merge(kind, seed)
end

-- "disk": the split file read off a mounted disk drive's disk, if one is present.
local function diskSource(concern)
  local kind = KIND[concern]
  local drive = peripheral.find("drive")
  if not drive or not drive.isDiskPresent or not drive.isDiskPresent() then return nil end
  local mount = drive.getMountPath and drive.getMountPath()
  if not mount then return nil end
  local body = realRead("/" .. mount .. "/" .. cfgspec.FILES[kind])
  if body == nil then return nil end
  local saved = textutils.unserialise(body)
  if type(saved) ~= "table" then return nil end
  return cfgspec.merge(kind, saved)
end

-- Wait for one cfgsync "cfg" reply (or the timeout) on `link`, updating `client`.
-- Bounded by a real CraftOS timer so a silent UI PC can never hang the boot.
local function waitForReply(link, client, kind, timeoutSec)
  local timer = os.startTimer(timeoutSec)
  while true do
    local ev, p1, p2, p3, p4 = os.pullEvent()
    if ev == "modem_message" then
      local decoded = link:onMessage(p2, p4)
      if decoded then
        local status = client:onFrame(decoded)
        if status == "done" then return client.received[kind] end
      end
    elseif ev == "timer" and p1 == timer then
      return nil
    end
  end
end

-- "ui": request the config from the UI PC's FCS SYNC responder over CFG_CH, with a
-- timeout + a couple of retries. Returns nil on no answer (caller shows the fallback
-- message: "UI SYNC not responding -- start FCS SYNC on the UI, or pick Disk / Own / Defaults").
--
-- The UI-side responder (ui/cfgserver.lua's Server:onMessage -> fcs.comms.cfgsync's
-- Responder.decide) answers with the RAW serialised file body it read off disk -- a STRING, not a
-- table -- so `client.received[kind]` (what waitForReply returns) is that same raw string.
-- loader.resolve, though, hands the concern's cfg straight to cfgspec.validate(kind, cfg), which
-- expects an actual TABLE. Unserialise here before returning: an unparseable body (corrupt
-- transmission, or a stale/incompatible responder) is treated as "no answer this attempt" rather
-- than handing loader.resolve a raw string it can't validate.
local function uiSource(concern)
  local modem = peripheral.find("modem")
  if not modem then return nil end
  local link = modemlib.wrap(modem, { txCh = M.CFG_CH.req, rxCh = M.CFG_CH.reply })
  local kind = KIND[concern]
  for attempt = 1, UI_RETRIES do
    local client = cfgsync.Client.new({
      sid = tostring(os.epoch("utc")) .. "-" .. attempt,
      kinds = { kind }, timeout = UI_TIMEOUT,
    })
    local frame = client:next()
    while frame do
      link:send(frame)
      frame = client:next()
    end
    local body = waitForReply(link, client, kind, UI_TIMEOUT)
    if body ~= nil then
      local ok, parsed = pcall(textutils.unserialise, body)
      if ok and type(parsed) == "table" then return parsed end
    end
  end
  return nil
end

-- Real sources table: get(concern, src) -> cfgTable | nil.
function M.buildSources()
  return {
    get = function(concern, src)
      if src == "own" then return ownSource(concern) end
      if src == "disk" then return diskSource(concern) end
      if src == "ui" then return uiSource(concern) end
      if src == "defaults" and concern == "tuning" then return tuningdefaults.get() end
      return nil
    end,
  }
end

local CONCERNS = { "binding", "sensor", "tuning" }
local LABEL = { binding = "BINDING", sensor = "SENSOR", tuning = "TUNING" }

local function diskIndicator()
  local drive = peripheral.find("drive")
  if not drive then return "no disk drive" end
  if not (drive.isDiskPresent and drive.isDiskPresent()) then return "no disk inserted" end
  local label = (drive.getDiskLabel and drive.getDiskLabel()) or "unlabeled"
  return "disk: " .. tostring(label)
end

local function ownIndicator(concern)
  local kind = KIND[concern]
  local body = realRead("/" .. cfgspec.FILES[kind])
  if body then
    local okp, parsed = pcall(textutils.unserialise, body)
    if okp and type(parsed) == "table" then return "split file present" end
    return "split file CORRUPT"
  end
  if realRead(LEGACY_CONFIG_PATH) then return "legacy read-through" end
  return "none available"
end

-- Render one concern's menu, read a pick, and return the chosen source string, the
-- sentinel "ABORT" on 'q', or nil on an invalid choice (caller re-prompts).
local function pickSource(concern)
  print("")
  print(("== %s source ==  (%s)"):format(LABEL[concern], diskIndicator()))
  local opts = loader.SOURCES[concern]
  for i, s in ipairs(opts) do
    local extra = (s == "own") and ("  [" .. ownIndicator(concern) .. "]") or ""
    print(("  %d) %s%s"):format(i, s, extra))
  end
  write("choice (q aborts): ")
  local input = read()
  if input == "q" then return "ABORT" end
  local ch = tonumber(input)
  return ch and opts[ch] or nil
end

-- Close the cfgsync request/reply channels the "ui" source may have opened, so the flight
-- app boots with a clean modem (best-effort; in-game only).
local function closeCfgChannels()
  local modem = peripheral.find("modem")
  if modem and modem.close then
    pcall(modem.close, M.CFG_CH.req)
    pcall(modem.close, M.CFG_CH.reply)
  end
end

-- After a source is picked for a concern, if it's external (M.needsConfirm), ask the pilot
-- to confirm before it overwrites the FCS runtime config. Loops until a clear Y/N answer;
-- mirrors confirmBoot's read/lower/y-n idiom.
local function confirmSource(concern, src)
  while true do
    write(LABEL[concern] .. " from " .. src .. " will overwrite the FCS runtime config -- proceed? (Y/N): ")
    local input = (read() or ""):lower()
    if input == "y" or input == "yes" then return true end
    if input == "n" or input == "no" then return false end
    print("  please answer Y or N")
  end
end

-- Prompt for one concern until a valid source is picked; returns the source, or "ABORT" on 'q'.
-- External sources ("disk"/"ui") are confirmed with the pilot before being accepted -- on N,
-- re-pick the same concern; "own"/"defaults" proceed silently.
local function pickUntilValid(concern)
  while true do
    local src = pickSource(concern)
    while src == nil do
      print("  invalid choice, try again")
      src = pickSource(concern)
    end
    if src == "ABORT" then return src end
    if not M.needsConfirm(src) then return src end
    if confirmSource(concern, src) then return src end
  end
end

-- After the config is written (and before the boot question), ask whether to run FCS
-- instrumentation/logging for THIS instance. y/yes -> true (logging on until reboot + N), n/no ->
-- false. Loops until a clear answer. Mirrors confirmBoot's read/lower/y-n idiom.
local function confirmLogging()
  while true do
    print("")
    write("Enable FCS logging? (Y/N): ")
    local input = (read() or ""):lower()
    if input == "y" or input == "yes" then return true end
    if input == "n" or input == "no" then return false end
    print("  please answer Y or N")
  end
end

-- After a successful write, ask the pilot whether to boot the FCS now. Loops until a clear
-- answer; returns true (start the flight app with the chosen config) or false (return to the
-- console -- the config is on disk, nothing is started). Accepts y/yes and n/no, any case.
local function confirmBoot()
  while true do
    print("")
    write("FCS config complete -- boot FCS? (Y/N): ")
    local input = (read() or ""):lower()
    if input == "y" or input == "yes" then return true end
    if input == "n" or input == "no" then return false end
    print("  please answer Y or N")
  end
end

-- Full interactive boot loop. Only place read()/term is touched. On a successful resolve the config
-- is written, then the pilot is asked whether to enable logging and whether to boot: returns
-- `assembled {hw=,tuning=}, logging(bool)` if they choose to boot, or nil if they decline (config
-- saved, nothing started) or abort. The launcher turns `logging` into _G.EH2_FLIGHTLOG.
function M.run()
  local sources = M.buildSources()
  print("EH2 BOOT LOADER")
  local choices = {}
  local toPick = CONCERNS   -- first pass picks all three; later passes re-pick only the failed one
  while true do
    for _, concern in ipairs(toPick) do
      local src = pickUntilValid(concern)
      if src == "ABORT" then return nil end
      choices[concern] = src
    end

    print("")
    print("resolving...")
    local ok, assembled, err, failedConcern = M.finish(choices, sources)
    if ok then
      print("OK -- wrote " .. HW_CONFIG_PATH .. " + " .. TUNING_PATH)
      closeCfgChannels()
      -- Logging choice comes first (per the boot-flow spec), then the boot question. The launcher
      -- turns `logging` into _G.EH2_FLIGHTLOG for tools/flight.lua.
      local logging = confirmLogging()
      if confirmBoot() then
        return assembled, logging
      end
      print("returning to console (config saved, FCS not started)")
      return nil
    end
    print("FAILED: " .. tostring(err))
    if failedConcern and LABEL[failedConcern] then
      print("re-pick " .. LABEL[failedConcern])
      toPick = { failedConcern }   -- keep the other concerns' picks; only redo the one that failed
    else
      print("please re-pick")
      toPick = CONCERNS
    end
  end
end

return M
