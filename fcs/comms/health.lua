-- fcs/comms/health.lua
local M = {}

local Tx = {}; Tx.__index = Tx
M.Tx = { new = function(cfg)
  return setmetatable({ period = (cfg and cfg.period) or 1.0, last = nil }, Tx)
end }
function Tx:beat(now)
  if self.last == nil or (now - self.last) >= self.period then
    self.last = now
    return { k = "hb", t = now }
  end
  return nil
end

local Rx = {}; Rx.__index = Rx
M.Rx = { new = function(cfg)
  return setmetatable({ timeout = (cfg and cfg.timeout) or 2.0, lastSeen = nil }, Rx)
end }
function Rx:mark(now) self.lastSeen = now end
function Rx:up(now)
  return self.lastSeen ~= nil and (now - self.lastSeen) <= self.timeout
end

return M
