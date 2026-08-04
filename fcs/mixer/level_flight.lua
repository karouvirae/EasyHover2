local Mixer = {}
Mixer.__index = Mixer
function Mixer.new() return setmetatable({}, Mixer) end
local function clamp(v) if v < 0 then return 0 elseif v > 1 then return 1 else return v end end
local YAW_DIR = { YFL = 1, YFR = -1, YRL = -1, YRR = 1 }
function Mixer:mixYaw(yaw)
  local out = {}
  for id, dir in pairs(YAW_DIR) do out[id] = clamp(dir * (yaw or 0)) end
  return out
end
function Mixer:mix(d)
  local h, p, r = d.heave or 0, d.pitch or 0, d.roll or 0
  local out = {
    FL = clamp(h + p + r), FR = clamp(h + p - r),
    RL = clamp(h - p + r), RR = clamp(h - p - r),
  }
  for id, duty in pairs(self:mixYaw(d.yaw)) do out[id] = duty end
  return out
end
return Mixer
