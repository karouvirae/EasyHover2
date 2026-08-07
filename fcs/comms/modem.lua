local protocol = require("fcs.comms.protocol")
local M = {}
local Link = {}; Link.__index = Link

function M.wrap(dev, cfg)
  if dev.open then pcall(dev.open, cfg.rxCh) end
  return setmetatable({ dev = dev, txCh = cfg.txCh, rxCh = cfg.rxCh }, Link)
end

function Link:send(frame)
  self.dev.transmit(self.txCh, self.rxCh, protocol.encode(frame))
end

function Link:onMessage(channel, str)
  if channel ~= self.rxCh then return nil end
  return protocol.decode(str)
end

return M
