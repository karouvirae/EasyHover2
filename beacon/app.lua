-- beacon/app.lua
-- Boots a GPS beacon: load config, wrap the ender modem, then run an EVENT-DRIVEN loop that
-- broadcasts on a timer and sleeps between broadcasts (os.startTimer + os.pullEvent -- never a busy
-- wait, so the shared CC server budget is safe). All the logic is in beacon.runtime / beacon.console
-- (both unit-tested); this file is the peripheral + event glue, kept thin.
local config = require("beacon.config")
local Runtime = require("beacon.runtime")
local Console = require("beacon.console")

local M = {}

-- A stable, unique id even before anyone configures one: the computer's label, else its id.
local function autoId()
  local label = os.getComputerLabel and os.getComputerLabel()
  if label and #label > 0 then return label end
  return "beacon-" .. tostring(os.getComputerID and os.getComputerID() or 0)
end

-- Find the ender/wireless modem: the configured side if given, else the first wireless modem.
local function findModem(side)
  if side and peripheral.isPresent(side) then
    local m = peripheral.wrap(side)
    if m and m.isWireless then return m, side end
  end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local m = peripheral.wrap(name)
      if m.isWireless and m.isWireless() then return m, name end
    end
  end
  return nil, nil
end

function M.run()
  local saved = config.load(config.PATH)
  local cfg = config.withDefaults(saved or {})
  if cfg.id == nil then cfg.id = autoId() end

  local modem, side = findModem(cfg.modemSide)
  if modem then modem.open(cfg.channel) end
  cfg.modemSide = side

  local rt = Runtime.new({ config = cfg, modem = modem, now = function() return os.epoch("utc") end })

  local function repaint()
    local model = {
      selfCheck = rt:selfCheck(), constellation = rt:constellation(),
      peers = rt:peers(), seq = rt.seq,
    }
    local w, h = term.getSize()
    Console.draw(Console.render(cfg, model, w), w, h)
  end

  local function save() config.save(config.PATH, cfg) end

  local function armBroadcast()
    return os.startTimer(config.clampInterval(cfg.intervalMs) / 1000)
  end

  repaint()
  local broadcastTimer = armBroadcast()
  local repaintTimer = os.startTimer(1)   -- keep the mesh/age readout current between broadcasts

  while true do
    local ev = { os.pullEvent() }
    local name = ev[1]
    if name == "timer" then
      if ev[2] == broadcastTimer then
        rt:broadcast()
        broadcastTimer = armBroadcast()   -- re-arm AFTER sending, then sleep on pullEvent again
      elseif ev[2] == repaintTimer then
        repaint()
        repaintTimer = os.startTimer(1)
      end
    elseif name == "modem_message" then
      -- side, channel, replyChannel, message, distance
      rt:onModemMessage(ev[3], ev[4], ev[5], ev[6])
    elseif name == "char" then
      local action = Console.actionFor(ev[2])
      if action == "quit" then
        term.setCursorPos(1, 1); term.clear(); print("beacon stopped"); return
      elseif action == "toggleEnabled" then
        cfg.enabled = not (cfg.enabled ~= false); save(); repaint()
      elseif action == "verify" then
        rt:broadcast(); repaint()
      elseif action == "setPosition" then
        term.clear()
        for i, line in ipairs(Console.positionHeader()) do term.setCursorPos(1, i); term.write(line) end
        term.setCursorPos(1, #Console.positionHeader() + 1)
        local pos, err = Console.readPosition(read, cfg.pos)
        if pos then cfg.pos = pos; save() else print(err); os.sleep(2) end
        repaint()
      end
    end
  end
end

return M
