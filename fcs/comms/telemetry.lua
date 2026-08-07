-- fcs/comms/telemetry.lua
local M = {}

local Tx = {}; Tx.__index = Tx
M.Tx = { new = function() return setmetatable({ seq = 0 }, Tx) end }
function Tx:frame(snapshot)
  self.seq = self.seq + 1
  return { k = "tel", seq = self.seq, s = snapshot }
end

local Rx = {}; Rx.__index = Rx
M.Rx = { new = function() return setmetatable({ lastSeq = 0, snapshot = nil }, Rx) end }
function Rx:accept(frame)
  if type(frame) ~= "table" or frame.k ~= "tel" then return false end
  if type(frame.seq) ~= "number" or frame.seq <= self.lastSeq then return false end
  self.lastSeq = frame.seq
  self.snapshot = frame.s
  return true
end
function Rx:latest() return self.snapshot end

return M
