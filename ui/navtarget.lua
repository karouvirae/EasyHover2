-- ui/navtarget.lua
-- PURE waypoint-targeting math for the PFD steering cue. Given the craft's horizontal position +
-- heading + baro altitude and a target waypoint, compute the compass bearing to it, the horizontal
-- distance, the relative steer angle (left/right), and the altitude delta (climb/descend).
--
-- Minecraft axes: +X is EAST, +Z is SOUTH (north is -Z). Compass: N=0, E=90, S=180, W=270.
-- No peripherals/Basalt; the caller (ui/basalt/app.lua buildState) feeds craft + target in.
local M = {}

local function wrap360(d)
  d = d % 360
  if d < 0 then d = d + 360 end
  return d
end

-- signed shortest difference a - b in (-180, 180]; positive = target is to the RIGHT of heading.
local function signedDelta(a, b)
  return ((a - b + 180) % 360) - 180
end

--- solve(craft, tgt) -> { bearing, distanceH, relBearing, altDelta } | nil.
--- craft = { x, z, heading?, baroY? } (heading/baroY optional -> relBearing/altDelta nil).
--- tgt   = { x, y, z }.
function M.solve(craft, tgt)
  if type(craft) ~= "table" or type(tgt) ~= "table" then return nil end
  if type(craft.x) ~= "number" or type(craft.z) ~= "number" then return nil end
  if type(tgt.x) ~= "number" or type(tgt.z) ~= "number" then return nil end

  local dx, dz = tgt.x - craft.x, tgt.z - craft.z
  local bearing = wrap360(math.deg(math.atan2(dx, -dz)))   -- +X east, -Z north
  local distanceH = math.sqrt(dx * dx + dz * dz)

  local relBearing = nil
  if type(craft.heading) == "number" then relBearing = signedDelta(bearing, craft.heading) end

  local altDelta = nil
  if type(tgt.y) == "number" and type(craft.baroY) == "number" then altDelta = tgt.y - craft.baroY end

  return { bearing = bearing, distanceH = distanceH, relBearing = relBearing, altDelta = altDelta }
end

return M
