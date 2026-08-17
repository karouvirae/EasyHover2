-- ui/routefollow.lua
-- PURE route-following progress for the NAV menu's active route. Given the route's resolved legs
-- (nav.waypoints.resolveLegs) + the current leg index + the craft's horizontal position, pick the
-- active leg (skipping legs whose waypoint was deleted), detect arrival within the radius, and
-- auto-advance to the next leg. Display/advance only -- no flying (that's the future A/P). No
-- peripherals/Basalt; the caller (ui/basalt/app.lua buildState) feeds craft + legs in.
local M = {}

--- currentLeg(legs, i) -> leg, index : the first RESOLVED leg at or after i, or nil (none from here).
function M.currentLeg(legs, i)
  legs = legs or {}
  i = math.max(1, math.floor(i or 1))
  for k = i, #legs do
    if legs[k] and legs[k].resolved then return legs[k], k end
  end
  return nil, nil
end

--- arrived(leg, craft, radius) -> true when the craft is within `radius` blocks (horizontal) of the
--- resolved leg. Default radius 50.
function M.arrived(leg, craft, radius)
  if not (leg and leg.resolved and craft and type(craft.x) == "number" and type(craft.z) == "number") then
    return false
  end
  local dx, dz = leg.x - craft.x, leg.z - craft.z
  return math.sqrt(dx * dx + dz * dz) <= (radius or 50)
end

--- step(legs, i, craft, radius) -> { i, target, arrived, atEnd }. The active target is the current
--- resolved leg's { name, x, y, z }; if the craft has arrived and it's not the last leg, i advances
--- to the next resolved leg. `y` is the per-leg altitude. Clamps at the final leg.
function M.step(legs, i, craft, radius)
  legs = legs or {}
  local leg, k = M.currentLeg(legs, i)
  if not leg then return { i = i or 1, target = nil, arrived = false, atEnd = true } end
  local arrived = M.arrived(leg, craft, radius)
  local ni = k
  if arrived and k < #legs then
    local nleg, nk = M.currentLeg(legs, k + 1)
    if nleg then ni = nk; leg = nleg end
  end
  return {
    i = ni,
    target = { name = leg.wpt, x = leg.x, y = leg.y, z = leg.z },
    arrived = arrived,
    atEnd = (ni >= #legs),
  }
end

return M
