-- fcs/comms/protocol.lua
local M = {}

function M.encode(frame)
  return textutils.serialize(frame)
end

function M.decode(str)
  if type(str) ~= "string" then return nil end
  local ok, val = pcall(textutils.unserialize, str)
  if not ok or type(val) ~= "table" then return nil end
  return val
end

return M
