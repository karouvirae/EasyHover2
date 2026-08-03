local frame = require("fcs.frame")
local Sim = {}
Sim.__index = Sim
-- corner geometry: FL front-left, FR front-right, RL rear-left, RR rear-right
local FRONT = { FL = 1, FR = 1, RL = -1, RR = -1 }   -- +1 front, -1 rear
local RIGHT = { FL = -1, FR = 1, RL = -1, RR = 1 }   -- +1 right, -1 left
function Sim.new(cfg)
  local self = setmetatable({ cfg = cfg, on = {} }, Sim)
  self.altitude, self.vSpeed = 0, 0
  self.pitch, self.pitchRate = 0, 0
  self.roll, self.rollRate = 0, 0
  for _, id in ipairs(frame.LIFT) do self.on[id] = false end
  return self
end
function Sim:liftIds() return frame.LIFT end
function Sim:setThruster(id, s) self.on[id] = s and true or false end
function Sim:step(dt)
  local c = self.cfg
  local fz, pm, rm = 0, 0, 0
  for _, id in ipairs(frame.LIFT) do
    if self.on[id] then
      fz = fz + c.fPer
      pm = pm + c.fPer * FRONT[id] * c.armZ
      rm = rm + c.fPer * RIGHT[id] * c.armX
    end
  end
  local aV = fz / c.mass - c.g
  self.vSpeed = self.vSpeed + aV * dt
  self.altitude = self.altitude + self.vSpeed * dt
  if self.altitude < 0 then self.altitude = 0; if self.vSpeed < 0 then self.vSpeed = 0 end end
  self.pitchRate = self.pitchRate + (pm / c.inertia) * dt
  self.pitch = self.pitch + self.pitchRate * dt
  self.rollRate = self.rollRate + (rm / c.inertia) * dt
  self.roll = self.roll + self.rollRate * dt
end
function Sim:sensors()
  return { altitude = self.altitude, vSpeed = self.vSpeed,
           pitch = self.pitch, pitchRate = self.pitchRate,
           roll = self.roll, rollRate = self.rollRate,
           onGround = (self.altitude <= 0 and math.abs(self.vSpeed) < 0.01) }
end
return Sim
