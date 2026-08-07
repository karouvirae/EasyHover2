-- fcs/comms/command.lua
local M = {}

local Sender = {}; Sender.__index = Sender
M.Sender = { new = function(cfg)
  return setmetatable({ timeout = (cfg and cfg.timeout) or 1.0,
                        nextId = 0, pending = {} }, Sender)
end }
function Sender:send(cmd)
  self.nextId = self.nextId + 1
  local frame = { k = "cmd", id = self.nextId, cmd = cmd }
  self.pending[self.nextId] = { frame = frame, age = 0 }
  return frame
end
function Sender:ack(id) self.pending[id] = nil end
function Sender:tick(dt)
  local due = {}
  for _, p in pairs(self.pending) do
    p.age = p.age + dt
    if p.age >= self.timeout then p.age = 0; due[#due + 1] = p.frame end
  end
  return due
end

local Receiver = {}; Receiver.__index = Receiver
M.Receiver = { new = function()
  return setmetatable({ handled = {} }, Receiver)
end }
function Receiver:receive(frame, apply)
  if type(frame) ~= "table" or frame.k ~= "cmd" or type(frame.id) ~= "number" then
    return nil
  end
  if not self.handled[frame.id] then
    self.handled[frame.id] = true
    apply(frame.cmd)
  end
  return { k = "ack", id = frame.id }
end

return M
