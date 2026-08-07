local M = {}
function M.pair()
  local a = { _type = "modem", _peer = nil, _in = {} }
  local b = { _type = "modem", _peer = nil, _in = {} }
  a._peer, b._peer = b, a
  local function mk(self)
    self.open = function(_) end
    self.isWireless = function() return false end
    self.transmit = function(tx, rx, msg)
      self._peer._in[#self._peer._in + 1] = { channel = tx, replyChannel = rx, message = msg }
    end
    self.inbox = function() local q = self._in; self._in = {}; return q end
    return self
  end
  return mk(a), mk(b)
end
return M
