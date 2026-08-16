-- tools/beaconupdate.lua
-- PURE/injected core of the beacon updater: broadcast one token-guarded update command and collect
-- the acks beacons send just before they reboot. No real peripherals -- deps.transmit / deps.pull are
-- injected (launchers/beaconupdate.lua wires the real ender modem). Fail-closed: refuses to send
-- without a valid token, the same gate the beacons enforce on receipt (beacon/update.lua).
local Update = require("beacon.update")

local M = {}
M.DEFAULT_TIMEOUT = 2.5   -- seconds to wait for acks after the broadcast

--- run(deps) -> { ok, responders?, err? }. deps:
---   token             the shared secret (must match the beacons' updateToken)
---   channel           the GPS/update channel (default 65000)
---   transmit(ch,reply,msg)  send a frame
---   pull(timeoutS) -> ackId | nil   next ack's beacon id, or nil when the window elapses
---   timeoutS          optional ack window (default DEFAULT_TIMEOUT)
function M.run(deps)
  deps = deps or {}
  if not Update.validToken(deps.token) then
    return { ok = false, err = "no valid update token set -- refusing to broadcast" }
  end
  local timeoutS = deps.timeoutS or M.DEFAULT_TIMEOUT
  deps.transmit(deps.channel, deps.channel, Update.encode(Update.command(deps.token)))

  local seen, order = {}, {}
  while true do
    local id = deps.pull(timeoutS)
    if id == nil then break end
    if not seen[id] then seen[id] = true; order[#order + 1] = id end
  end
  table.sort(order, function(a, b) return tostring(a) < tostring(b) end)
  return { ok = true, responders = order }
end

return M
