-- beacon/runtime.lua
-- A GPS beacon's behaviour, Basalt-free and peripheral-injected so it self-tests headless. A beacon
--   (1) periodically BROADCASTS { id, x, y, z, seq } on the GPS channel (the launcher, T4, owns the
--       sleep-between-broadcasts timer -- this module just builds + sends one frame per call, so it
--       can never busy-wait);
--   (2) HEARS the other beacons on the same channel (via the shared nav receiver) and, from that
--       mesh, runs a SELF-CHECK -- measured range vs configured geometry -- to catch a typo'd
--       coordinate, plus a constellation grade so a beacon screen can say whether NAV can get a fix.
-- Reception + broadcasting live only on beacon/NAV computers; the FCS never opens this channel.
local gpsproto = require("nav.comms.gpsproto")
local Receiver = require("nav.comms.receiver")
local geometry = require("nav.lib.geometry")

local M = {}
local R = {}
R.__index = R

M.DEFAULT_TOLERANCE = 1.0   -- blocks: configured-vs-measured range disagreement above this = MISMATCH

--- Plain Euclidean distance between two {x,y,z}.
function M.geoDistance(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function validPos(p)
  return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

--- selfCheck(selfPos, peers, tolerance) -> { ok, checked, mismatches = {{id,measured,expected,delta}} }.
--- peers: { [id] = { pos={x,y,z}, dist=n|nil } } (receiver:beacons()). Only peers with a measured
--- distance are checkable; results sorted by id for a stable screen.
function M.selfCheck(selfPos, peers, tolerance)
  tolerance = tolerance or M.DEFAULT_TOLERANCE
  local mism, checked = {}, 0
  if validPos(selfPos) then
    for id, p in pairs(peers or {}) do
      if type(p.dist) == "number" and validPos(p.pos) then
        checked = checked + 1
        local expected = M.geoDistance(selfPos, p.pos)
        local delta = math.abs(p.dist - expected)
        if delta > tolerance then
          mism[#mism + 1] = { id = id, measured = p.dist, expected = expected, delta = delta }
        end
      end
    end
  end
  table.sort(mism, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return { ok = (#mism == 0), checked = checked, mismatches = mism }
end

--- constellation(selfPos, peers) -> geometry.grade over this beacon + every heard peer position.
function M.constellation(selfPos, peers)
  local list = {}
  if validPos(selfPos) then list[#list + 1] = { x = selfPos.x, y = selfPos.y, z = selfPos.z } end
  local ids = {}
  for id in pairs(peers or {}) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  for _, id in ipairs(ids) do
    local p = peers[id]
    if validPos(p.pos) then list[#list + 1] = { x = p.pos.x, y = p.pos.y, z = p.pos.z } end
  end
  return geometry.grade(list)
end

--- new(opts): config (beacon.config-shaped), modem (raw dev with .transmit/.open), now (fn->ms),
--- receiver (defaults to a fresh nav receiver on the config channel).
function M.new(opts)
  opts = opts or {}
  local cfg = opts.config or {}
  return setmetatable({
    config = cfg,
    modem = opts.modem,
    now = opts.now or function() return os.epoch("utc") end,
    seq = 0,
    receiver = opts.receiver or Receiver.new({ channel = cfg.channel, now = opts.now }),
  }, R)
end

--- Can this beacon broadcast right now? Needs an enabled, id'd, positioned config + a modem.
function R:ready()
  local c = self.config
  return c.enabled ~= false and c.id ~= nil and validPos(c.pos) and c.channel ~= nil and self.modem ~= nil
end

--- Build one broadcast frame at the current seq.
function R:frame()
  local c = self.config
  return { id = c.id, x = c.pos.x, y = c.pos.y, z = c.pos.z, seq = self.seq }
end

--- Send one broadcast (seq++). Returns true if sent, false if not ready. The launcher calls this on
--- a timer and sleeps between calls -- never a busy loop.
function R:broadcast()
  if not self:ready() then return false end
  self.seq = self.seq + 1
  self.modem.transmit(self.config.channel, self.config.channel, gpsproto.encode(self:frame()))
  return true
end

--- Feed a raw modem_message (channel, replyChannel, msg, distance) to the mesh receiver.
function R:onModemMessage(channel, replyChannel, msg, distance)
  return self.receiver:onMessage(channel, replyChannel, msg, distance)
end

--- The heard peers, excluding our own id (a stray self-echo never counts as a peer).
function R:peers(now)
  local all = self.receiver:beacons(now)
  if self.config.id ~= nil then all[self.config.id] = nil end
  return all
end

function R:selfCheck(now)
  return M.selfCheck(self.config.pos, self:peers(now), self.config.tolerance)
end

function R:constellation(now)
  return M.constellation(self.config.pos, self:peers(now))
end

return M
