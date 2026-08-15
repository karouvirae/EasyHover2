-- nav/lib/fix.lua
-- Assemble the canonical NAV fix record. The NAV runtime (T5) trilaterates a position, grades the
-- constellation, and ages the observations; this module packs that into one flat record the runtime
-- relays to the craft wire and the UI renders:
--   { x, y, z, age, quality, source, nBeacons }
-- so downstream (Phase 2 autopilot) can honestly refuse a stale or low-quality fix. Pure: no clock,
-- no peripherals -- `age` is supplied by the caller (the receiver measures it). Unknown quality is
-- left nil rather than fabricated. Copies the position so a later mutation of the source can't
-- corrupt a stored fix.
local M = {}

--- make(pos, meta) -> fix record, or nil if `pos` is not a complete {x,y,z}.
--- meta (all optional): age (ms, default 0), source (default "gps"), nBeacons (default 0), quality.
function M.make(pos, meta)
  if type(pos) ~= "table"
     or type(pos.x) ~= "number" or type(pos.y) ~= "number" or type(pos.z) ~= "number" then
    return nil
  end
  meta = meta or {}
  return {
    x = pos.x, y = pos.y, z = pos.z,
    age = meta.age or 0,
    source = meta.source or "gps",
    nBeacons = meta.nBeacons or 0,
    quality = meta.quality,
    errorEst = meta.errorEst,   -- estimated position error radius (blocks), from geometry dilution
  }
end

return M
