local frame = require("fcs.frame")
local Backend = {}
Backend.__index = Backend
function Backend.new(shim, config, clock)
  local self = setmetatable({}, Backend)
  self.shim = shim; self.config = config
  self.clock = clock or function() return os.epoch("utc") end
  self.wrapped = {}                 -- name -> peripheral cache
  self.lastT, self.lastAlt, self.vFilt = nil, nil, 0
  self.swayPos, self.surgePos = 0, 0
  return self
end
function Backend:_periph(name)
  if not name then return nil end
  if self.wrapped[name] == nil then self.wrapped[name] = self.shim.wrap(name) or false end
  return self.wrapped[name] or nil
end
function Backend:setThruster(id, on)
  local p = self:_periph(self.config.thrusters[id])
  if p then p.setThrust(on and 15 or 0) end   -- CC wrapped peripherals take NO self
end
function Backend:_read(name, method, ...)
  local p = self:_periph(name)
  if not p then return nil end
  return p[method](...)   -- CC wrapped peripherals take NO self
end
function Backend:sensors()
  local c, b = self.config, self.config.bindings
  local rawAlt = self:_read(c.sensors.altimeter, "getHeight") or 0
  local altitude = rawAlt + (b.heightOffset or 0)
  local angles = self:_read(c.sensors.gimbal, "getAngles") or {0, 0}
  local pitch = (b.signPitch or 1) * (angles[b.gimbalPitchIdx or 1] or 0)
  local roll  = (b.signRoll  or 1) * (angles[b.gimbalRollIdx  or 2] or 0)
  local heading = self:_read(c.sensors.navTable, "getRelativeAngle") or 0
  local vf = (b.signVelFront or 1) * (self:_read(c.sensors.velFront, "getVelocity") or 0)
  local vr = (b.signVelRear  or 1) * (self:_read(c.sensors.velRear,  "getVelocity") or 0)
  local vm = (b.signVelMedial or 1) * (self:_read(c.sensors.velMedial,"getVelocity") or 0)
  local baseline = b.yawBaseline or 1
  local yawRate = (vf - vr) / (baseline ~= 0 and baseline or 1)
  local swayVel = (vf + vr) / 2
  local surgeVel = vm
  local optD = self:_read(c.sensors.downOptical, "getDistance")
  local onGround = (optD ~= nil) and (optD < (b.onGroundThreshold or 1.5)) or false

  local now = self.clock()
  local vSpeed = 0
  if self.lastT ~= nil then
    local dt = (now - self.lastT) / 1000
    if dt > 0 then
      local rawV = (altitude - self.lastAlt) / dt
      local tau = b.vSpeedTau or 0
      local alpha = tau > 0 and (dt / (tau + dt)) or 1
      self.vFilt = self.vFilt + alpha * (rawV - self.vFilt)
      vSpeed = self.vFilt
      self.swayPos = self.swayPos + swayVel * dt
      self.surgePos = self.surgePos + surgeVel * dt
    end
  end
  self.lastT, self.lastAlt = now, altitude
  return { altitude=altitude, vSpeed=vSpeed, pitch=pitch, roll=roll, heading=heading,
    yawRate=yawRate, swayVel=swayVel, surgeVel=surgeVel, swayPos=self.swayPos, surgePos=self.surgePos,
    onGround=onGround }
end
function Backend:liftIds() return frame.LIFT end
function Backend:lateralIds() return frame.LATERAL end
function Backend:mainIds() return frame.MAIN end
function Backend:frontalIds() return frame.FRONTAL end
return Backend
