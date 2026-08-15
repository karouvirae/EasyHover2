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

-- Geometry VALIDITY (grade) answers "can these hosts fix at all". But a valid, non-coplanar
-- constellation can still be nearly useless if it is clustered far to one side of the receiver:
-- a tiny distance error then maps to a huge position error (geometric dilution of precision).
-- pdop() measures that dilution AT the solved position, so the quality readout can be honest
-- instead of reporting a perfect fix that is 11 blocks off. Larger PDOP = worse.
M.DOP_GOOD = 3.0    -- PDOP at or below this = excellent geometry (quality 1.0)
M.DOP_BAD  = 12.0   -- PDOP at or above this = effectively unusable (quality 0.0)
M.UERE     = 0.5    -- assumed per-beacon distance uncertainty in blocks (CC rounding + block offset)

--- pdop(hosts, atPos) -> Position Dilution of Precision, or nil (<4 hosts / degenerate).
--- H rows = unit line-of-sight vectors from atPos to each host; PDOP = sqrt(trace((H^T H)^-1)).
function M.pdop(hosts, atPos)
  if type(hosts) ~= "table" or #hosts < M.REQUIRED_HOSTS or type(atPos) ~= "table" then return nil end
  -- Accumulate the normal matrix N = H^T H (sum of outer products of the unit LOS vectors).
  local N = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
  local used = 0
  for _, ho in ipairs(hosts) do
    local dx, dy, dz = atPos.x - ho.x, atPos.y - ho.y, atPos.z - ho.z
    local r = math.sqrt(dx * dx + dy * dy + dz * dz)
    if r > 1e-6 then
      used = used + 1
      local ux, uy, uz = dx / r, dy / r, dz / r
      N[1][1] = N[1][1] + ux * ux; N[1][2] = N[1][2] + ux * uy; N[1][3] = N[1][3] + ux * uz
      N[2][1] = N[2][1] + uy * ux; N[2][2] = N[2][2] + uy * uy; N[2][3] = N[2][3] + uy * uz
      N[3][1] = N[3][1] + uz * ux; N[3][2] = N[3][2] + uz * uy; N[3][3] = N[3][3] + uz * uz
    end
  end
  if used < M.REQUIRED_HOSTS then return nil end
  -- trace of N^-1: only the diagonal cofactors / det are needed.
  local a, b, c = N[1][1], N[1][2], N[1][3]
  local d, e, f = N[2][1], N[2][2], N[2][3]
  local g, h, i = N[3][1], N[3][2], N[3][3]
  local det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
  if math.abs(det) < 1e-12 then return nil end
  local invDiag = ((e * i - f * h) + (a * i - c * g) + (a * e - b * d)) / det
  if invDiag <= 0 then return nil end
  return math.sqrt(invDiag)
end

--- dopQuality(pdop, uere) -> { quality (0..1), errorEst (blocks), pdop }. Maps dilution to a
--- confidence and an expected error radius so the pilot knows whether to trust the fix.
function M.dopQuality(pdop, uere)
  uere = uere or M.UERE
  if type(pdop) ~= "number" then return { quality = 0, errorEst = nil, pdop = nil } end
  local q
  if pdop <= M.DOP_GOOD then q = 1.0
  elseif pdop >= M.DOP_BAD then q = 0.0
  else q = (M.DOP_BAD - pdop) / (M.DOP_BAD - M.DOP_GOOD) end
  return { quality = q, errorEst = pdop * uere, pdop = pdop }
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
