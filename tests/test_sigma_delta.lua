local t = require("tests.framework")
local SigmaDelta = require("fcs.actuate.sigma_delta")
local function recBackend()
  local b = { writes = 0, on = {} }
  function b:setThruster(id, s) self.writes = self.writes + 1; self.on[id] = s end
  return b
end
t.test("duty 1 always on, duty 0 always off", function()
  local b = recBackend(); local sd = SigmaDelta.new({ backend = b })
  for _ = 1, 20 do sd:apply({ a = 1.0, z = 0.0 }, 0.1) end
  t.truthy(sd:state("a") == true); t.truthy(sd:state("z") == false)
end)
t.test("average on-fraction tracks a fractional duty", function()
  local b = recBackend(); local sd = SigmaDelta.new({ backend = b })
  local onCount, N = 0, 400
  for _ = 1, N do sd:apply({ a = 0.25 }, 0.1); if sd:state("a") then onCount = onCount + 1 end end
  t.near(onCount / N, 0.25, 0.02)              -- density matches duty
end)
t.test("resolves a small duty the coarse PWM would quantise away", function()
  local b = recBackend(); local sd = SigmaDelta.new({ backend = b })
  local onCount, N = 0, 1000
  for _ = 1, N do sd:apply({ a = 0.05 }, 0.1); if sd:state("a") then onCount = onCount + 1 end end
  t.near(onCount / N, 0.05, 0.02)              -- ~5% density, not 0 and not 33%
end)
