local Mixer = {}
Mixer.__index = Mixer
function Mixer.new() return setmetatable({ com = { fwd = 0, right = 0, span = 0 } }, Mixer) end
function Mixer:setCom(com)
  com = com or {}
  self.com = {
    fwd = tonumber(com.fwd) or 0,
    right = tonumber(com.right) or 0,
    span = tonumber(com.span) or 0,
  }
  return self
end

function Mixer.offsetFromDuties(d, span)
  span = span or 0
  if not d or span < 0.05 then return { fwd = 0, right = 0 } end
  local h = ((d.FL or 0) + (d.FR or 0) + (d.RL or 0) + (d.RR or 0)) / 4
  if math.abs(h) < 1e-6 then return { fwd = 0, right = 0 } end
  local p = ((d.FL or 0) + (d.FR or 0)) / 2 - h
  local r = ((d.FL or 0) + (d.RL or 0)) / 2 - h
  return { fwd = span * p / h, right = -span * r / h }
end
local function clamp(v) if v < 0 then return 0 elseif v > 1 then return 1 else return v end end
local YAW_DIR = { YFL = 1, YFR = -1, YRL = -1, YRR = 1 }
local SWAY_DIR = { YFL = 1, YFR = -1, YRL = 1, YRR = -1 }
local YAWREAR_DIR = { YRL = -1, YRR = 1 }   -- rear pair only; YFL/YFR absent => 0
function Mixer:mixLateral(sway, yaw, yawRear)
  local out = {}
  for id, ydir in pairs(YAW_DIR) do
    out[id] = clamp((SWAY_DIR[id] or 0) * (sway or 0)
                  + ydir * (yaw or 0)
                  + (YAWREAR_DIR[id] or 0) * (yawRear or 0))
  end
  return out
end
function Mixer:mixYaw(yaw) return self:mixLateral(0, yaw) end
function Mixer:mixSurge(surge)
  surge = surge or 0
  return {
    MAIN = surge > 0 and clamp(surge) or 0,
    FRL  = surge < 0 and clamp(-surge) or 0,
    FRR  = surge < 0 and clamp(-surge) or 0,
  }
end
-- Attitude-priority ("airmode") lift mix. The pitch/roll differential is the attitude torque
-- and MUST survive; the collective (heave) is expendable. So instead of clamping each thruster
-- independently -- which silently destroys the differential once the collective pushes a
-- thruster past a rail (Flight #5: roll authority vanished at the heave band floor -> flip) --
-- we (1) scale pitch+roll TOGETHER if the requested differential can't fit in [0,1] at all, then
-- (2) shift all four lift thrusters by one common offset to slide them into range, which keeps
-- every pairwise difference (hence the torque) intact. Collective accuracy is sacrificed first.
local function corners(h, p, r, com)
  local arm = (com and com.span) or 0
  if arm < 0.05 then
    return h + p + r, h + p - r, h - p + r, h - p - r
  end
  local cap = arm * 0.9
  local cy = com.fwd or 0
  local cx = com.right or 0
  if cy > cap then cy = cap elseif cy < -cap then cy = -cap end
  if cx > cap then cx = cap elseif cx < -cap then cx = -cap end
  local kyF = (arm + cy) / arm
  local kyR = (arm - cy) / arm
  local kxL = (arm - cx) / arm
  local kxR = (arm + cx) / arm
  return h * kyF * kxL + p + r, h * kyF * kxR + p - r,
         h * kyR * kxL - p + r, h * kyR * kxR - p - r
end

local function mixLift(h, p, r, com)
  local FL, FR, RL, RR = corners(h, p, r, com)
  local lo = math.min(FL, FR, RL, RR)
  local hi = math.max(FL, FR, RL, RR)
  local dutySpan = hi - lo
  if dutySpan > 1 then
    local s = 1 / dutySpan
    p, r = p * s, r * s
    FL, FR, RL, RR = corners(h, p, r, com)
    lo = math.min(FL, FR, RL, RR); hi = math.max(FL, FR, RL, RR)
  end
  local offset = 0
  if lo < 0 then offset = -lo elseif hi > 1 then offset = 1 - hi end
  return clamp(FL + offset), clamp(FR + offset), clamp(RL + offset), clamp(RR + offset)
end
function Mixer:mix(d)
  local FL, FR, RL, RR = mixLift(d.heave or 0, d.pitch or 0, d.roll or 0, self.com)
  local out = { FL = FL, FR = FR, RL = RL, RR = RR }
  for id, duty in pairs(self:mixLateral(d.sway, d.yaw, d.yawRear)) do out[id] = duty end
  for id, duty in pairs(self:mixSurge(d.surge)) do out[id] = duty end
  return out
end
return Mixer
