-- ui/cfgserver.lua
-- Pure server object for config sync: holds a running flag and lastSeen timestamp.
-- Routes hello/req frames to cfgsync.Responder if running, building a provider from
-- injected read() and dir. Frames always update lastSeen. No modem/peripherals here.
local cfgsync = require("fcs.comms.cfgsync")
local cfgspec = require("fcs.io.cfgspec")

local Server = {}; Server.__index = Server

local M = {}

function M.new(cfg)
  cfg = cfg or {}
  return setmetatable({
    read = cfg.read,
    dir = cfg.dir or "/",
    _running = false,
    _lastSeen = nil,
  }, Server)
end

function Server:start()
  self._running = true
end

function Server:stop()
  self._running = false
end

function Server:running()
  return self._running
end

function Server:onMessage(frame)
  -- Update lastSeen on any hello or req frame
  if type(frame) == "table" and (frame.k == "hello" or frame.k == "req") then
    self._lastSeen = os.epoch("utc")
  end

  -- If not running, don't answer
  if not self._running then return nil end

  -- Build provider that reads from dir + FILES[kind]
  local provider = function(kind)
    return self.read(self.dir .. cfgspec.FILES[kind])
  end

  return cfgsync.Responder.decide(frame, provider)
end

function Server:status()
  return { running = self._running, lastSeen = self._lastSeen }
end

return M
