-- nav/runtime.lua
-- The NAV computer's brain, peripheral-injected so it self-tests headless. It:
--   * HEARS the broadcast GPS on the shared channel (nav.comms.receiver), TRILATERATES a position
--     (nav.lib.trilaterate) and grades the constellation (nav.lib.geometry) into a quality;
--   * CONSUMES the FCS's own telemetry snapshot (ch 101, decoded via fcs.comms.telemetry's Rx in
--     nav/app.lua, stored here via R:onFcsSnapshot) for its heading -- compassHeading is the FCS's
--     own compass reading, so NAV no longer reads a navigation_table of its own at all;
--   * RELAYS a {fix} frame onto the craft's WIRED network (fcs/comms/modem Link) -- the FCS ignores
--     this in Batch 1 (it never opens the relay channel).
-- Reception/trilateration live ONLY here (never on the FCS), so this can't starve the flight loop.
-- The app loop (T6) pumps modem_message in and calls :step() on a low-rate timer -- event-driven,
-- never a busy wait.
local Receiver = require("nav.comms.receiver")
local trilaterate = require("nav.lib.trilaterate")
local geometry = require("nav.lib.geometry")
local heading = require("nav.lib.heading")
local fix = require("nav.lib.fix")
local modem = require("fcs.comms.modem")

local M = {}
local R = {}
R.__index = R

--- Horizontal ground speed (blocks/s) between two fixes; nil on first/absent fix or non-positive dt.
--- y is deliberately ignored -- a hovercraft navigates horizontally (matches the HDOP-honest quality).
function M.groundSpeed(prevFix, prevT, fix, now)
  if type(prevFix) ~= "table" or type(fix) ~= "table" or prevT == nil then return nil end
  local dt = (now - prevT) / 1000
  if dt <= 0 then return nil end
  local dx, dz = fix.x - prevFix.x, fix.z - prevFix.z
  return math.sqrt(dx * dx + dz * dz) / dt
end

--- new(opts): config (nav.config-shaped), gpsModem (raw, for reception -- opened by the app),
--- wiredModem (raw, for relay), now (fn->ms), receiver (defaults to a fresh nav receiver on the
--- config channel + staleMs = thresholds.maxAgeMs). No navtable -- heading comes from the FCS's own
--- telemetry snapshot (R:onFcsSnapshot).
function M.new(opts)
  opts = opts or {}
  local cfg = opts.config or {}
  local th = cfg.thresholds or {}
  local self = setmetatable({
    config = cfg,
    gpsModem = opts.gpsModem,
    now = opts.now or function() return os.epoch("utc") end,
    receiver = opts.receiver or Receiver.new({
      channel = cfg.channel, staleMs = th.maxAgeMs or 3000, now = opts.now,
    }),
    -- PARAMS extras: disk rides navfix only while paramsWatch is on.
    paramsWatch = false,
    disk = false,
  }, R)
  -- The relay link (fire-and-forget onto the wired network). Injected `link` wins (tests), else
  -- wrap the wired modem on the relay channel.
  if opts.link then
    self.link = opts.link
  elseif opts.wiredModem and cfg.relay and cfg.relay.channel then
    self.link = modem.wrap(opts.wiredModem, { txCh = cfg.relay.channel, rxCh = cfg.relay.channel })
  end
  return self
end

--- Feed a raw GPS modem_message (channel, replyChannel, msg, distance) to the receiver.
function R:onModemMessage(channel, replyChannel, msg, distance)
  return self.receiver:onMessage(channel, replyChannel, msg, distance)
end

--- computeFix(now) -> fix record | nil, grade. Builds observations from the fresh heard beacons,
--- trilaterates, and tags age (the oldest contributing observation) + a GDOP-aware quality.
function R:computeFix(now)
  now = now or self.now()
  local bmap = self.receiver:beacons(now)
  local ids = {}
  for id, b in pairs(bmap) do if type(b.dist) == "number" then ids[#ids + 1] = id end end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)

  local obs, positions, maxAge = {}, {}, 0
  for _, id in ipairs(ids) do
    local b = bmap[id]
    obs[#obs + 1] = { pos = b.pos, dist = b.dist }
    positions[#positions + 1] = { x = b.pos.x, y = b.pos.y, z = b.pos.z }
    if (b.ageMs or 0) > maxAge then maxAge = b.ageMs end
  end

  local pos = trilaterate.solve(obs)
  local grade = geometry.grade(positions)
  if not pos then return nil, grade end
  -- Trust the fix only if the constellation is valid AND well-conditioned AT this position: a
  -- distant/clustered constellation grades usable but has huge dilution, so quality must reflect
  -- the GDOP, not just host count (the in-game "q 1.00 but 11 blocks off" bug). We grade on
  -- HORIZONTAL dilution (HDOP), not 3D PDOP: MC beacons all sit near build height, so vertical
  -- dilution is irreducibly huge and would falsely read POOR even with a sub-block horizontal fix
  -- (the "wide flat spread reads ~40 blk" bug). The craft navigates horizontally; altitude comes
  -- from baro. See nav/lib/geometry.lua:hdop.
  local dq = geometry.dopQuality(geometry.hdop(positions, pos))
  -- Grade quality on HORIZONTAL geometry + host count only -- NOT grade.usable. geometry.grade()
  -- flags a near-coplanar constellation (all beacons near build height) as unusable for CC
  -- gps.locate()'s 3D mirror rule, but EH2 trilaterates real slant ranges and still nails the
  -- horizontal fix, so coplanarity must not zero horizontal quality (the "wide flat spread reads
  -- POOR ~40 blk" bug). Horizontal degeneracy still yields quality 0 -- a horizontally ill-
  -- conditioned set gives a huge HDOP (or nil for a fully degenerate one), and dopQuality maps both
  -- to 0. Vertical/gpsAlt trust is a separate Batch-B concern.
  local enoughHosts = (grade.usableHosts or 0) >= geometry.REQUIRED_HOSTS
  local quality = enoughHosts and dq.quality or 0.0
  return fix.make(pos, { age = maxAge, source = "gps", nBeacons = #obs,
    quality = quality, errorEst = dq.errorEst }), grade
end

--- Store the latest FCS telemetry snapshot (nav/app.lua decodes ch 101 via fcs.comms.telemetry's
--- Rx and calls this on every accepted frame). R:heading reads compassHeading off it.
function R:onFcsSnapshot(snap)
  self._fcsSnap = snap
end

--- The heading from the FCS's own compass, as broadcast in its telemetry snapshot -- nil until the
--- first snapshot has arrived, or if that snapshot carries no compassHeading.
function R:heading()
  return self._fcsSnap and self._fcsSnap.compassHeading or nil
end

--- PARAMS watch (UI fire-and-forget on the wpt request link). Seed disk once on the rising
--- edge via an injected probe; later disk/disk_eject events flip self.disk locally.
--- frame() publishes disk only while this flag is on.
function R:onParamsWatch(on, diskPresent)
  on = on and true or false
  if on and not self.paramsWatch and diskPresent then
    self.disk = diskPresent() and true or false
  end
  self.paramsWatch = on
end

--- Build the GPS fix relay frame (fix may be nil so the craft still learns NAV is alive). Heading is
--- NOT bundled here -- the FCS broadcasts its own compassHeading directly; NAV just reads it back.
function R:frame(now)
  now = now or self.now()
  local f = self:computeFix(now)
  local gs = M.groundSpeed(self._lastFix, self._lastT, f, now)
  if f then self._lastFix, self._lastT = f, now end
  local out = { k = "navfix", fix = f, gs = gs, at = now }
  if self.paramsWatch then out.disk = self.disk and true or false end
  return out
end

--- Compute + relay one GPS fix frame onto the wired network. Fire-and-forget (latest-wins).
function R:step(now)
  local frame = self:frame(now)
  if self.link then self.link:send(frame) end
  return frame
end

--- A view-model for the NAV UI (T6): the current fix, heading + compass, grade, and heard beacons.
function R:status(now)
  now = now or self.now()
  local f, grade = self:computeFix(now)
  local hdg = self:heading()
  return {
    fix = f,
    heading = hdg,
    compass = hdg and heading.compass(hdg) or "--",
    grade = grade,
    beacons = self.receiver:beacons(now),
  }
end

return M
