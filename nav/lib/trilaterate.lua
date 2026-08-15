-- nav/lib/trilaterate.lua
-- Multilateration for the broadcast GPS: solve a receiver's world position from >=4 beacon
-- observations `{ pos = {x,y,z}, dist = <blocks> }` (the beacon's broadcast coordinates plus the
-- CC per-message `distance`). Because the EH2 GPS is passive/broadcast, it does NOT use CC's
-- request-based gps.locate() -- this is our own solver.
--
-- Method: take beacon 1 as the reference and subtract its sphere equation |X-P1|^2 = r1^2 from
-- each of the next three, which cancels the quadratic |X|^2 term and linearises into a 3x3 system
-- A*X = b. The determinant of A is the degeneracy guard: coplanar/collinear hosts make it ~0, and
-- we return nil rather than a garbage (or mirror-ambiguous) fix. Pure; no globals/peripherals.
local M = {}

local function det3(m)
  return m[1][1] * (m[2][2] * m[3][3] - m[2][3] * m[3][2])
       - m[1][2] * (m[2][1] * m[3][3] - m[2][3] * m[3][1])
       + m[1][3] * (m[2][1] * m[3][2] - m[2][2] * m[3][1])
end

--- obs: array of { pos = {x,y,z}, dist = n }. Returns { x, y, z } or nil (too few / degenerate).
function M.solve(obs)
  if type(obs) ~= "table" or #obs < 4 then return nil end
  local p1, r1 = obs[1].pos, obs[1].dist
  local s1 = p1.x * p1.x + p1.y * p1.y + p1.z * p1.z

  local A, b = {}, {}
  for i = 2, 4 do
    local p, r = obs[i].pos, obs[i].dist
    A[i - 1] = { 2 * (p.x - p1.x), 2 * (p.y - p1.y), 2 * (p.z - p1.z) }
    local si = p.x * p.x + p.y * p.y + p.z * p.z
    b[i - 1] = (si - s1) - (r * r - r1 * r1)
  end

  local D = det3(A)
  if math.abs(D) < 1e-9 then return nil end   -- coplanar / collinear -> no unique fix

  local function colReplaced(col)
    local m = { { A[1][1], A[1][2], A[1][3] },
                { A[2][1], A[2][2], A[2][3] },
                { A[3][1], A[3][2], A[3][3] } }
    m[1][col], m[2][col], m[3][col] = b[1], b[2], b[3]
    return m
  end

  return {
    x = det3(colReplaced(1)) / D,
    y = det3(colReplaced(2)) / D,
    z = det3(colReplaced(3)) / D,
  }
end

return M
