-- EasyHover 2 — guided sensor calibration.
-- Pure helpers here are headless-tested; the interactive run() shell (added later)
-- is in-game only. Wrapped peripherals take NO self: p.getAngles(), p.getVelocity().
local cal = require("fcs.io.calibration")
local M = {}

function M.average(nums)
  if #nums == 0 then return 0 end
  local s = 0; for _, v in ipairs(nums) do s = s + v end
  return s / #nums
end

function M.peakByAbs(nums)
  local best = 0
  for _, v in ipairs(nums) do if math.abs(v) > math.abs(best) then best = v end end
  return best
end

function M.argmaxAbs(nums)
  local bi, bv = 1, -1
  for i, v in ipairs(nums) do if math.abs(v) > bv then bv = math.abs(v); bi = i end end
  return bi
end

function M.applyGimbal(config, axis, result)
  local b = config.bindings
  if axis == "pitch" then b.gimbalPitchIdx = result.idx; b.signPitch = result.sign
  else b.gimbalRollIdx = result.idx; b.signRoll = result.sign end
  b.gimbalScale = result.scale
  return config
end

function M.applyLateral(config, result)
  local b = config.bindings
  b.signVelFront = result.signFront; b.signVelRear = result.signRear; b.signYawRate = result.signYawRate
  return config
end

function M.applyScalarSign(config, key, sign) config.bindings[key] = sign; return config end

function M.applyHeading(config, result)
  local b = config.bindings
  b.signHeading = result.sign; b.headingScale = result.scale
  return config
end

function M.applyGround(config, heightOffset, threshold)
  local b = config.bindings
  b.heightOffset = heightOffset; b.onGroundThreshold = threshold
  return config
end

function M.applyConstants(config, yawBaseline, baroThrusterOffset)
  local b = config.bindings
  b.yawBaseline = yawBaseline; b.baroThrusterOffset = baroThrusterOffset
  return config
end

return M
