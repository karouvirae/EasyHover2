-- fcs/comms/protocol.lua
local M = {}

-- CC:Tweaked 1.97+ textutils.serialize(t, { compact = true }) omits pretty-printer
-- whitespace (rom/apis/textutils.lua). Telemetry is 10 Hz; newlines are airtime.
-- pcall-fallback: older serializers that reject the opts table still encode.
function M.encode(frame)
  local ok, str = pcall(textutils.serialize, frame, { compact = true })
  if ok then return str end
  return textutils.serialize(frame)
end

function M.decode(str)
  if type(str) ~= "string" then return nil end
  local ok, val = pcall(textutils.unserialize, str)
  if not ok or type(val) ~= "table" then return nil end
  return val
end

return M
