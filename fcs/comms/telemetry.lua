-- fcs/comms/telemetry.lua
local session = require("fcs.comms.session")
local M = {}

local Tx = {}; Tx.__index = Tx
M.Tx = { new = function() return setmetatable({ seq = 0, sid = session.new() }, Tx) end }
function Tx:frame(snapshot)
  self.seq = self.seq + 1
  return { k = "tel", sid = self.sid, seq = self.seq, s = snapshot }
end

local Rx = {}; Rx.__index = Rx
M.Rx = { new = function() return setmetatable({ sid = nil, lastSeq = 0, snapshot = nil }, Rx) end }
function Rx:accept(frame)
  if type(frame) ~= "table" or frame.k ~= "tel" then return false end
  if type(frame.seq) ~= "number" then return false end
  -- A new session id means the FCS rebooted and its seq reset to 1. Reset the watermark so the
  -- fresh stream is accepted immediately, instead of being rejected as "stale" (seq <= old max)
  -- until seq climbs all the way back -- which froze the reported state (and the panel) for 15-30s.
  if frame.sid ~= self.sid then
    self.sid = frame.sid
    self.lastSeq = 0
  end
  if frame.seq <= self.lastSeq then return false end
  self.lastSeq = frame.seq
  self.snapshot = frame.s
  return true
end
function Rx:latest() return self.snapshot end

return M
