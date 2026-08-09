-- fcs/comms/session.lua
-- A per-boot session id for the comms channels. Both channels use monotonic counters that RESET
-- on restart -- command ids (UI side) and telemetry seq (FCS side) -- and the receiving side must
-- not mistake a fresh post-restart stream for stale/duplicate traffic. Tagging every stream with a
-- session id lets the receiver detect a restart (sid changed) and reset its watermark. os.epoch is
-- monotonic-per-boot (reboots are milliseconds apart at minimum); the random suffix is belt-and-braces.
local M = {}

function M.new()
  local t = (os.epoch and os.epoch("utc")) or (os.time and os.time() * 1000) or 0
  return tostring(t) .. "-" .. tostring(math.random(0, 1000000))
end

return M
