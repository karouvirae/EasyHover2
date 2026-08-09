-- fcs/input/pilot.lua
local leash = require("fcs.leash")
local angle = require("fcs.angle")

local Pilot = {}
Pilot.__index = Pilot

function Pilot.new(cfg)
  return setmetatable({
    cfg = cfg,
    sp = { altitude = 0, heading = 0, swayPos = 0, surgePos = 0 },
    hold = false,
  }, Pilot)
end

function Pilot:reset(meas)
  self.sp = { altitude = meas.altitude, heading = meas.heading,
              swayPos = meas.swayPos, surgePos = meas.surgePos }
  return self.sp
end

function Pilot:setPositionHold(b) self.hold = b and true or false end

local function dirOf(held, neg, pos)
  return (held[pos] and 1 or 0) - (held[neg] and 1 or 0)
end

function Pilot:update(dt, held, meas)
  if self.hold then return self.sp end
  local c, sp = self.cfg, self.sp

  -- Yaw: slew heading setpoint, angle-wrapped, leashed to lead the CURRENT heading by at most
  -- leadCapHeading. Without the leash a long yaw hold runs the setpoint far ahead; the craft chases
  -- that lead, builds yaw momentum, and keeps turning for seconds after release then overshoots.
  -- Mirrors the altitude (leadCapVert) and position (maxLead) leashes.
  local yd = dirOf(held, "yawLeft", "yawRight")
  if yd ~= 0 then
    sp.heading = angle.wrap(sp.heading + c.headingRate * dt * yd)
    local cap = c.leadCapHeading
    if cap then
      local err = angle.wrap(sp.heading - (meas.heading or 0))
      if err > cap then sp.heading = angle.wrap((meas.heading or 0) + cap)
      elseif err < -cap then sp.heading = angle.wrap((meas.heading or 0) - cap) end
    end
  end

  -- Lift: slew altitude, leashed to current altitude +/- leadCapVert.
  local ld = dirOf(held, "down", "up")
  if ld ~= 0 then
    local a = sp.altitude + c.climbRate * dt * ld
    local lo, hi = meas.altitude - c.leadCapVert, meas.altitude + c.leadCapVert
    if a < lo then a = lo elseif a > hi then a = hi end
    sp.altitude = a
  end

  -- Sway / surge: leashed position setpoints. Held => ramp toward maxLead in
  -- that direction at cruiseSpeed; released => hold current setpoint.
  local swd = dirOf(held, "swayLeft", "swayRight")
  local starget = (swd ~= 0) and (meas.swayPos + c.maxLead * swd) or sp.swayPos
  sp.swayPos = leash.step(sp.swayPos, starget, meas.swayPos, dt, c.cruiseSpeed, c.maxLead)

  local sud = dirOf(held, "surgeBack", "surgeFwd")
  local utarget = (sud ~= 0) and (meas.surgePos + c.maxLead * sud) or sp.surgePos
  sp.surgePos = leash.step(sp.surgePos, utarget, meas.surgePos, dt, c.cruiseSpeed, c.maxLead)

  return sp
end

return Pilot
