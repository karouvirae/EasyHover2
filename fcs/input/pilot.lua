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
    policy = { tilt = false, surge = "position" },
    tilt = { pitch = 0, roll = 0 },
    throttle = 0,
    climbHeld = 0,
    yawWasHeld = false,
  }, Pilot)
end

function Pilot:reset(meas)
  self.sp = { altitude = meas.altitude, heading = meas.heading,
              swayPos = meas.swayPos, surgePos = meas.surgePos }
  self.yawWasHeld = false
  return self.sp
end

function Pilot:setPositionHold(b) self.hold = b and true or false end

function Pilot:setMode(policy, feel)
  self.policy = policy or { tilt = false, surge = "position" }
  if feel then self.cfg = feel end
  self.tilt.pitch, self.tilt.roll, self.throttle, self.climbHeld = 0, 0, 0, 0   -- transition: center tilt, drop throttle
end

function Pilot:setTrimDir(dir) self.cfg.trimDir = (dir and dir < 0) and -1 or 1 end

local function dirOf(held, neg, pos)
  return (held[pos] and 1 or 0) - (held[neg] and 1 or 0)
end

function Pilot:update(dt, held, meas)
  if self.hold then return self.sp end
  local c, sp = self.cfg, self.sp

  -- Yaw: slew heading setpoint, angle-wrapped, leashed to lead the CURRENT heading by at most
  -- leadCapHeading. The leash bounds the standing lead (hence the steady turn RATE) while held;
  -- mirrors the altitude (leadCapVert) and position (maxLead) leashes. The post-release coast --
  -- the craft continuing to turn out the remaining lead -- is killed separately by the release-edge
  -- capture near the end of update() (snaps the setpoint to current heading + a small stop lead).
  local yd = dirOf(held, "yawLeft", "yawRight")
  local yawActive = (yd ~= 0)   -- set true again by the CPL rudder block; drives release-capture below
  if yd ~= 0 then
    sp.heading = angle.wrap(sp.heading + c.headingRate * dt * yd)
    local cap = c.leadCapHeading
    if cap then
      local err = angle.wrap(sp.heading - (meas.heading or 0))
      if err > cap then sp.heading = angle.wrap((meas.heading or 0) + cap)
      elseif err < -cap then sp.heading = angle.wrap((meas.heading or 0) - cap) end
    end
  end

  -- Lift: slew altitude, leashed to current altitude +/- leadCapVert. In coupled mode the rate
  -- ramps with hold time (tap = base climbRate nudge, sustained hold -> climbRate*(1+climbBoost)).
  local ld = dirOf(held, "down", "up")
  local climbRate = c.climbRate
  if self.policy.surge == "coupled" then
    if ld ~= 0 then
      self.climbHeld = (self.climbHeld or 0) + dt
      local ramp = math.min(1, self.climbHeld / (c.climbRampTime or 1.0))
      climbRate = c.climbRate * (1 + (c.climbBoost or 0) * ramp)
    else
      self.climbHeld = 0
    end
  end
  if ld ~= 0 then
    local a = sp.altitude + climbRate * dt * ld
    local lo, hi = meas.altitude - c.leadCapVert, meas.altitude + c.leadCapVert
    if a < lo then a = lo elseif a > hi then a = hi end
    sp.altitude = a
  end

  -- Sway / surge: leashed position setpoints. Held => ramp toward the lead cap in that direction at
  -- the axis cruise speed; released => hold current setpoint. Surge (fore/aft, the main engine) and
  -- sway (lateral) have SEPARATE speed/lead so forward can be much faster than sideways; both fall
  -- back to the shared cruiseSpeed/maxLead when the split params are absent (keeps old configs valid).
  local swaySpeed, swayLead = c.swaySpeed or c.cruiseSpeed, c.swayLead or c.maxLead
  local swd = dirOf(held, "swayLeft", "swayRight")
  local starget = (swd ~= 0) and (meas.swayPos + swayLead * swd) or sp.swayPos
  sp.swayPos = leash.step(sp.swayPos, starget, meas.swayPos, dt, swaySpeed, swayLead)

  local surgeSpeed, surgeLead = c.surgeSpeed or c.cruiseSpeed, c.surgeLead or c.maxLead
  local sud = dirOf(held, "surgeBack", "surgeFwd")
  local utarget = (sud ~= 0) and (meas.surgePos + surgeLead * sud) or sp.surgePos
  sp.surgePos = leash.step(sp.surgePos, utarget, meas.surgePos, dt, surgeSpeed, surgeLead)

  -- MAN drift-relax: while the pilot actively tilts, relax the horizontal position hold so a
  -- banked craft drifts freely instead of the translate loop fighting it. Snapping the position
  -- setpoints to the measured position zeroes the loop error (no counter-thrust). Releasing tilt
  -- stops the snap, so the setpoints freeze at the current position and the loop re-holds wherever
  -- the drift ended. Overrides the leash above; only MAN sets policy.relaxTiltDrift.
  if self.policy.relaxTiltDrift then
    if held.pitchDown or held.pitchUp or held.rollLeft or held.rollRight then
      sp.swayPos = meas.swayPos
      sp.surgePos = meas.surgePos
    end
  end

  -- Coupled (CPL/DCPL) horizontal + rudder inputs. Runs before the tilt block so auto-trim can
  -- read self.throttle. The generic sway/surge leash above still ran; we override sp.surgePos/
  -- swayPos to the measured position while the pilot is actively commanding, so the CPL cushion
  -- holds wherever you stop rather than at a leashed-ahead point.
  if self.policy.surge == "coupled" then
    -- Throttle (L-Shift=surgeFwd): ramp up while held, decay to idle on release. Cap [0,1].
    if held.surgeFwd then self.throttle = self.throttle + (c.throttleRate or 1.0) * dt
    else self.throttle = self.throttle - (c.throttleDecay or 1.0) * dt end
    if self.throttle < 0 then self.throttle = 0 elseif self.throttle > 1 then self.throttle = 1 end
    -- Cushioned brake (Space=surgeBack): decel ~ forward speed, tapered to 0, cap 1.0.
    local brake = 0
    if held.surgeBack then
      brake = (c.brakeGain or 0.5) * math.max(0, meas.surgeVel or 0)
      if brake > 1.0 then brake = 1.0 end
    end
    -- Fine surge (arrows up/down).
    local fine = dirOf(held, "fineBack", "fineFwd") * (c.slowSurgeRate or 0.3)
    sp.surgeCmd = self.throttle - brake + fine
    sp.surgeActive = held.surgeFwd or held.surgeBack or (fine ~= 0) or false
    if sp.surgeActive then sp.surgePos = meas.surgePos end
    -- Strafe (arrows left/right = sway flags).
    local strafe = dirOf(held, "swayLeft", "swayRight") * (c.strafeRate or 0.3)
    sp.swayCmd = strafe
    sp.swayActive = (strafe ~= 0)
    if sp.swayActive then sp.swayPos = meas.swayPos end
    -- Rudder (Q/E): rear-only yaw. Same heading ramp + leash as the full-yaw block, flagged so the
    -- scheme reroutes to the rear-only effector this tick.
    local rd = dirOf(held, "rudderLeft", "rudderRight")
    if rd ~= 0 then
      yawActive = true                 -- rudder is a yaw input too -> same release-capture path
      sp.heading = angle.wrap(sp.heading + c.headingRate * dt * rd)
      local cap = c.leadCapHeading
      if cap then
        local err = angle.wrap(sp.heading - (meas.heading or 0))
        if err > cap then sp.heading = angle.wrap((meas.heading or 0) + cap)
        elseif err < -cap then sp.heading = angle.wrap((meas.heading or 0) - cap) end
      end
      sp.yawRear = true
    else
      sp.yawRear = false
    end
  end

  -- Mode policy: tilt (MAN pitch/roll setpoint, auto-levels on release) and throttle
  -- (CRUISE held forward-throttle). Applied here so the existing altitude/heading/sway/surge
  -- ramp logic above stays untouched; positionHold (self.hold) never reaches this point.
  if self.policy.tilt then
    local function toward(cur, dir, rate, cap)
      if dir ~= 0 then cur = cur + rate * dt * dir
      elseif cur > 0 then cur = math.max(0, cur - rate * dt)
      else cur = math.min(0, cur + rate * dt) end          -- auto-level toward 0 on release
      if cur >  cap then cur =  cap elseif cur < -cap then cur = -cap end
      return cur
    end
    self.tilt.pitch = toward(self.tilt.pitch, dirOf(held, "pitchDown", "pitchUp"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    self.tilt.roll  = toward(self.tilt.roll,  dirOf(held, "rollLeft",  "rollRight"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    if self.policy.surge == "coupled" then
      local trim = (c.trimGain or 0) * (c.trimDir or -1) * (self.throttle or 0)
      local p = self.tilt.pitch + trim
      -- Auto-trim gets its own headroom (trimCap) so it can command MORE nose-down than a manual
      -- tilt (tiltCap): the craft has no pitch-down surface, so countering surge accel needs the
      -- extra authority. Falls back to tiltCap when trimCap is absent (older configs).
      local cap = c.trimCap or c.tiltCap or 0.4
      if p > cap then p = cap elseif p < -cap then p = -cap end
      sp.pitch, sp.roll = p, self.tilt.roll
    else
      sp.pitch, sp.roll = self.tilt.pitch, self.tilt.roll
    end
  else
    sp.pitch, sp.roll = 0, 0
  end
  if self.policy.surge == "throttle" then
    local d = dirOf(held, "surgeBack", "surgeFwd")
    local maxT = c.cruiseThrottleMax or 1.0
    self.throttle = self.throttle + (c.cruiseThrottleRate or 1.0) * dt * d
    if self.throttle < 0 then self.throttle = 0 elseif self.throttle > maxT then self.throttle = maxT end
    sp.surgeThrottle = self.throttle
  end

  -- Yaw release-edge capture: on the tick the pilot lets go of yaw/rudder, drop the leashed lead
  -- and snap the heading setpoint to the current heading plus a small predictive stop
  -- (yawStopLead * yawRate), so the loop brakes to a halt where you released instead of coasting
  -- the ~leadCapHeading lead out -- the old oversteer. Edge-triggered (yawWasHeld): once captured,
  -- the setpoint stays fixed so the heading PID fights drift rather than re-tracking meas.heading.
  if yawActive then
    self.yawWasHeld = true
  elseif self.yawWasHeld then
    sp.heading = angle.wrap((meas.heading or 0) + (c.yawStopLead or 0) * (meas.yawRate or 0))
    self.yawWasHeld = false
  end

  -- Return a snapshot copy: sp is self.sp, mutated in place as internal ramp state across calls
  -- (needed so leash/tilt/throttle math can reference the previous tick's values). Callers that
  -- hold onto a returned setpoint across later update() calls (e.g. comparing tilt/throttle before
  -- and after release) must see the value AT THAT TICK, not a live view of ongoing mutation.
  local out = {}
  for k, v in pairs(sp) do out[k] = v end
  return out
end

return Pilot
