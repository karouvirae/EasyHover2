-- Pure climb/hold/land state machine for the hover bring-up runner. No CC dependencies.
local Profile = {}
Profile.__index = Profile

function Profile.new(cfg)
  cfg = cfg or {}
  local self = setmetatable({}, Profile)
  self.baseAlt = cfg.baseAlt or 0
  self.climbHeight = cfg.climbHeight or 5
  self.climbRate = cfg.climbRate or 1.0
  self.holdTime = cfg.holdTime or 10
  self.descendRate = cfg.descendRate or 0.7
  self.landEps = cfg.landEps or 0.4
  self.watchdog = cfg.watchdog or 30
  self.overshootMargin = cfg.overshootMargin or 2
  self.top = self.baseAlt + self.climbHeight
  self.phase = "IDLE"
  self.target = self.baseAlt
  self.elapsed = 0
  self.held = 0
  return self
end

function Profile:begin()
  if self.phase == "IDLE" then self.phase = "CLIMB"; self.elapsed = 0 end
end

function Profile:abort()
  if self.phase ~= "LANDED" then self.phase = "DESCEND" end
end

function Profile:update(dt, alt, onGround)
  dt = (dt and dt > 0) and dt or 0
  if self.phase ~= "IDLE" and self.phase ~= "LANDED" then
    self.elapsed = self.elapsed + dt
    if self.elapsed >= self.watchdog then self.phase = "DESCEND" end
    if alt and alt > self.top + self.overshootMargin then self.phase = "DESCEND" end
  end
  if self.phase == "CLIMB" then
    self.target = math.min(self.top, self.target + self.climbRate * dt)
    if self.target >= self.top then self.phase = "HOLD"; self.held = 0 end
  elseif self.phase == "HOLD" then
    self.target = self.top
    self.held = self.held + dt
    if self.held >= self.holdTime then self.phase = "DESCEND" end
  elseif self.phase == "DESCEND" then
    self.target = math.max(self.baseAlt, self.target - self.descendRate * dt)
    if (onGround == true) or (alt and alt <= self.baseAlt + self.landEps) then
      self.phase = "LANDED"
    end
  else -- IDLE or LANDED
    self.target = self.baseAlt
  end
  local active = self.phase == "CLIMB" or self.phase == "HOLD" or self.phase == "DESCEND"
  return { phase = self.phase, targetAlt = self.target, active = active,
           done = self.phase == "LANDED" }
end

return Profile
