-- Direct 16-level thruster actuator. Writes setPower(0..15) ONLY when a thruster's quantized
-- level changes -> a steady hover holds steady levels -> almost no writes -> the control loop
-- keeps its ~18Hz rate instead of collapsing to ~5Hz under time-domain PWM/sigma-delta toggling
-- (each setPower write costs ~50ms mainThread). Same interface as fcs/actuate/pwm.lua.
local Level = {}
Level.__index = Level

function Level.new(cfg)
  return setmetatable({ backend = cfg.backend, steps = cfg.steps or 15, last = {} }, Level)
end

function Level:state(id) return self.last[id] or 0 end

local function quantize(v, steps)
  v = math.floor(v + 0.5)
  if v < 0 then return 0 elseif v > steps then return steps else return v end
end

function Level:apply(duties, dt)
  for id, duty in pairs(duties) do
    local level = quantize((duty or 0) * self.steps, self.steps)
    if self.last[id] ~= level then
      self.last[id] = level
      self.backend:setThrusterLevel(id, level)
    end
  end
end

return Level
