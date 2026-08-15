-- nav/lib/geometry.lua
-- Constellation geometry grading: can this set of beacons yield a fix at all? Ported from
-- EasyHover 1's gps_beacon/lib/geometry.lua -- the rules come from CC's gps.locate() and matter
-- because every failure is silent:
--   * need 4 usable hosts (3 to trilaterate + 1 to resolve the mirror);
--   * hosts closer than 1 block merge into one host;
--   * 4 (near-)coplanar hosts cannot disambiguate the mirror image, so they give NO fix.
-- Used by both the beacon self-check screen and the NAV quality readout. Pure math.
local M = {}

M.REQUIRED_HOSTS = 4
M.MIN_SEPARATION = 1.0     -- fixes closer than this are merged by gps.locate() -> count once
M.COPLANAR_LIMIT = 0.02    -- normalised tetrahedron volume below this = effectively coplanar

local function dist(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Greedily drop any beacon within MIN_SEPARATION of one already kept.
local function distinct(beacons)
  local kept = {}
  for _, bcn in ipairs(beacons) do
    local dup = false
    for _, k in ipairs(kept) do
      if dist(bcn, k) < M.MIN_SEPARATION then dup = true; break end
    end
    if not dup then kept[#kept + 1] = bcn end
  end
  return kept
end

-- Normalised volume of the tetrahedron on the first 4 hosts (dimensionless): ~0 => coplanar.
local function coplanarity(h)
  local function sub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
  local u, v, w = sub(h[2], h[1]), sub(h[3], h[1]), sub(h[4], h[1])
  local vol = math.abs(u.x * (v.y * w.z - v.z * w.y)
                     - u.y * (v.x * w.z - v.z * w.x)
                     + u.z * (v.x * w.y - v.y * w.x)) / 6
  local scale = 0
  for _, e in ipairs({ u, v, w }) do
    local len = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z)
    if len > scale then scale = len end
  end
  if scale == 0 then return 0 end
  return vol / (scale * scale * scale)
end

--- grade(beacons) -> { usable, usableHosts, reasons = { ... } }
function M.grade(beacons)
  local kept = distinct(beacons or {})
  local n = #kept
  local reasons = {}
  local usable = true

  if n < M.REQUIRED_HOSTS then
    usable = false
    reasons[#reasons + 1] = ("only %d usable host(s); need %d"):format(n, M.REQUIRED_HOSTS)
  elseif coplanarity(kept) < M.COPLANAR_LIMIT then
    usable = false
    reasons[#reasons + 1] = "hosts are effectively coplanar -- the mirror cannot be resolved"
  end

  return { usable = usable, usableHosts = n, reasons = reasons }
end

return M
