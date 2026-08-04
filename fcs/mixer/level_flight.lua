local Mixer = {}
Mixer.__index = Mixer
function Mixer.new() return setmetatable({}, Mixer) end
local function clamp(v) if v < 0 then return 0 elseif v > 1 then return 1 else return v end end
function Mixer:mix(d)
  local h, p, r = d.heave or 0, d.pitch or 0, d.roll or 0
  return {
    FL = clamp(h + p + r), FR = clamp(h + p - r),
    RL = clamp(h - p + r), RR = clamp(h - p - r),
  }
end
return Mixer
