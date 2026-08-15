-- nav/lib/heading.lua
-- Absolute heading for the NAV computer, from ITS OWN navigation_table. A magnet in the table aims
-- it at TRUE NORTH, so `navigation_table.getRelativeAngle()` is already an ABSOLUTE bearing -- but
-- Create: Simulated's bytecode does not pin down which way it counts, so a calibrated sign (+1/-1)
-- corrects the direction (see docs/MOD_API_RESEARCH.md; same trap the FCS hit with signHeading).
-- Pure math: no peripherals, no globals, no state -- the runtime (T5) reads the table and feeds
-- the raw angle in. Unlike EH1's stateful gimbal-fusion heading, Batch 1 NAV has no gimbal, so this
-- is just the table's own bearing, sign-corrected and wrapped.
local M = {}

--- Normalise a bearing to [0, 360).
function M.wrap360(deg)
  deg = deg % 360
  if deg < 0 then deg = deg + 360 end
  return deg
end

--- Smallest signed difference a - b, in (-180, 180], so a turn across the 0/360 seam reads as a
--- small change rather than a ~359-degree jump.
function M.angleDelta(a, b)
  local d = M.wrap360(a - b)
  if d > 180 then d = d - 360 end
  return d
end

--- absolute(relAngle, sign) -> bearing in [0, 360), or nil if the table is silent.
--- `sign` defaults to +1; getRelativeAngle() may legitimately return nil.
function M.absolute(relAngle, sign)
  if type(relAngle) ~= "number" then return nil end
  sign = (sign == -1) and -1 or 1
  return M.wrap360(relAngle * sign)
end

-- 16-point compass, for a readout too narrow for numbers (ported from EH1 nav/lib/geo.lua).
local POINTS = { "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                 "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW" }

--- compass(deg) -> "N".."NNW", or "--" when there is no bearing.
function M.compass(deg)
  if type(deg) ~= "number" then return "--" end
  local idx = math.floor(M.wrap360(deg) / 22.5 + 0.5) % 16
  return POINTS[idx + 1]
end

--- calibrateSign(relBefore, relAfter, clockwise) -> +1 | -1 | nil.
--- The pilot rotates the craft a KNOWN direction and we compare two raw navtable readings. Compass
--- bearings increase clockwise, so a clockwise turn must make `absolute` increase -- pick the sign
--- that makes that true. `clockwise` defaults to true. Returns nil if the craft did not actually
--- turn (no signed change to measure).
function M.calibrateSign(relBefore, relAfter, clockwise)
  if type(relBefore) ~= "number" or type(relAfter) ~= "number" then return nil end
  local rawDelta = M.angleDelta(relAfter, relBefore)
  if rawDelta == 0 then return nil end
  local wantUp = clockwise ~= false        -- clockwise -> heading should go UP
  local rawUp = rawDelta > 0
  return (rawUp == wantUp) and 1 or -1
end

return M
