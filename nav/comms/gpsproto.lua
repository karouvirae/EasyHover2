-- nav/comms/gpsproto.lua
-- The broadcast GPS frame: a beacon periodically transmits { id, x, y, z, seq }. Reuses the FCS
-- wire format (fcs/comms/protocol.lua) for serialization, but adds GPS-specific validation so the
-- NAV receiver never trilaterates off a malformed or unrelated broadcast. Pure: no modem here.
local protocol = require("fcs.comms.protocol")
local M = {}

--- encode(frame) -> string. Keeps ONLY the GPS fields (a caller's stray fields do not ride along).
function M.encode(f)
  return protocol.encode({ id = f.id, x = f.x, y = f.y, z = f.z, seq = f.seq })
end

--- decode(str) -> { id, x, y, z, seq } or nil. Rejects garbage, a missing id, or a non-numeric
--- coordinate; `seq` is optional.
function M.decode(str)
  local f = protocol.decode(str)
  if type(f) ~= "table" then return nil end
  if f.id == nil then return nil end
  if type(f.x) ~= "number" or type(f.y) ~= "number" or type(f.z) ~= "number" then return nil end
  return { id = f.id, x = f.x, y = f.y, z = f.z, seq = f.seq }
end

return M
