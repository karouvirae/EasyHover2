-- nav/comms/receiver.lua
-- Passive aggregator for the broadcast GPS. Beacons transmit { id, x, y, z, seq } on the GPS
-- channel; CC attaches a per-message `distance` (the range to the sender for same-dimension
-- wireless). This receiver keys broadcasts by beacon id, remembers each beacon's position + measured
-- distance + arrival time, and hands the NAV runtime (T5) fresh {pos,dist} observations to
-- trilaterate. Pure: the clock is INJECTED, and no modem is touched here -- the runtime pumps raw
-- modem_message args in via :onMessage. This lives ONLY on the NAV pc (the FCS never opens this
-- channel), so it can never starve the flight loop.
local gpsproto = require("nav.comms.gpsproto")

local Receiver = {}
Receiver.__index = Receiver
local M = {}

--- new(opts): channel (nil = accept any), staleMs (default 5000), now (fn -> ms; default os.epoch).
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    channel = opts.channel,
    staleMs = opts.staleMs or 5000,
    now = opts.now or function() return os.epoch("utc") end,
    _beacons = {},   -- [id] = { pos = {x,y,z}, dist = n|nil, at = ms, seq = n|nil }
  }, Receiver)
end

--- Feed one modem_message: (channel, replyChannel, msg, distance). Returns true if a valid GPS
--- broadcast on our channel was stored, else false. `distance` may be nil (cross-dimension) -- we
--- still record the beacon's position (the mesh self-check can use it) but it won't be a usable
--- ranging observation.
function Receiver:onMessage(channel, _replyChannel, msg, distance)
  if self.channel ~= nil and channel ~= self.channel then return false end
  local f = gpsproto.decode(msg)
  if not f then return false end
  self._beacons[f.id] = {
    pos = { x = f.x, y = f.y, z = f.z },
    dist = (type(distance) == "number") and distance or nil,
    at = self.now(),
    seq = f.seq,
  }
  return true
end

--- observations(now) -> array of { pos, dist } for FRESH beacons that carry a distance, sorted by
--- id so the trilaterate subset is deterministic. Feed straight to nav.lib.trilaterate.solve.
function Receiver:observations(now)
  now = now or self.now()
  local ids = {}
  for id, b in pairs(self._beacons) do
    if type(b.dist) == "number" and (now - b.at) <= self.staleMs then ids[#ids + 1] = id end
  end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, id in ipairs(ids) do
    local b = self._beacons[id]
    out[#out + 1] = { pos = b.pos, dist = b.dist }
  end
  return out
end

--- beacons(now) -> { [id] = { pos, dist, ageMs, seq } } for every FRESH beacon heard (stale ones
--- dropped). For the NAV/beacon UIs and the mesh self-check; includes beacons heard without a
--- distance (pos still known).
function Receiver:beacons(now)
  now = now or self.now()
  local out = {}
  for id, b in pairs(self._beacons) do
    if (now - b.at) <= self.staleMs then
      out[id] = { pos = b.pos, dist = b.dist, ageMs = now - b.at, seq = b.seq }
    end
  end
  return out
end

return M
