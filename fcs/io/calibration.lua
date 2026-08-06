local M = {}

-- Shared tunables (UI and tests reference these).
M.FLOOR = 0.02        -- minimum dominant magnitude to trust a motion
M.RATIO = 3.0         -- dominant must beat runner-up by this factor
M.GIMBAL_DEG = 3.0    -- |delta| above this => gimbal emits degrees, not radians
M.HEADING_DEG = 10.0  -- |delta| above this => heading emits degrees

local function signOf(x) return x >= 0 and 1 or -1 end
M._signOf = signOf

function M.gate(dominant, runnerUp, floor, ratio)
  floor = floor or M.FLOOR; ratio = ratio or M.RATIO
  dominant = math.abs(dominant); runnerUp = math.abs(runnerUp)
  if dominant < floor then return "too-small" end
  if runnerUp > 0 and dominant < ratio * runnerUp then return "too-ambiguous" end
  return "ok"
end

function M.classifyScalarSign(neutralVal, sampleVal, opts)
  opts = opts or {}
  local floor = opts.floor or M.FLOOR
  local d = sampleVal - neutralVal
  return { sign = signOf(d), magnitude = math.abs(d),
           status = math.abs(d) >= floor and "ok" or "too-small" }
end

function M.classifyGimbalAxis(neutral, moved, opts)
  opts = opts or {}
  local degT = opts.degThreshold or M.GIMBAL_DEG
  local d1 = (moved[1] or 0) - (neutral[1] or 0)
  local d2 = (moved[2] or 0) - (neutral[2] or 0)
  local idx, dom, other
  if math.abs(d1) >= math.abs(d2) then idx, dom, other = 1, d1, d2
  else idx, dom, other = 2, d2, d1 end
  local unit = math.abs(dom) > degT and "deg" or "rad"
  local scale = unit == "deg" and (math.pi / 180) or 1
  return { idx = idx, sign = signOf(dom), unit = unit, scale = scale,
           dominant = math.abs(dom), runnerUp = math.abs(other),
           status = M.gate(dom, other, opts.floor, opts.ratio) }
end

function M.classifyLateralPair(neutral, swaySample, yawSample, opts)
  opts = opts or {}
  local floor, ratio = opts.floor, opts.ratio
  local sf = (swaySample.front or 0) - (neutral.front or 0)
  local sr = (swaySample.rear  or 0) - (neutral.rear  or 0)
  local yf = (yawSample.front or 0) - (neutral.front or 0)
  local yr = (yawSample.rear  or 0) - (neutral.rear  or 0)
  -- per-sensor sign from the sway sample: each sensor must read + for rightward
  local signFront, signRear = signOf(sf), signOf(sr)
  -- sway sample must be common-mode dominant (|sum| beats |difference|)
  local swayStatus = M.gate(sf + sr, sf - sr, floor, ratio)
  -- yaw sign from the differential of the sign-normalized yaw sample
  local diff = signFront * yf - signRear * yr
  local comm = signFront * yf + signRear * yr
  -- The differential (front-rear) cancels common-mode translation by construction, so
  -- its sign is the yaw sign no matter how much sway/surge the motion also carried. We
  -- therefore require ONLY that it clear the noise floor (a real rotation happened) --
  -- NOT that it dominate the common-mode. A plunger yaw pivots off-center and always
  -- carries translation; a ratio gate here wrongly rejects clean, obvious turns.
  local yawFloor = opts.yawFloor or M.FLOOR
  local yawStatus = math.abs(diff) >= yawFloor and "ok" or "too-small"
  return { signFront = signFront, signRear = signRear, signYawRate = signOf(diff),
           swayStatus = swayStatus, yawStatus = yawStatus,
           swayOk = swayStatus == "ok", yawOk = yawStatus == "ok",
           yawDiff = diff, yawComm = comm }
end

function M.detectHeadingScale(neutralHeading, sampleHeading, opts)
  opts = opts or {}
  local degT = opts.degThreshold or M.HEADING_DEG
  local floor = opts.floor or M.FLOOR
  local d = sampleHeading - neutralHeading
  local unit = math.abs(d) > degT and "deg" or "rad"
  local scale = unit == "deg" and (math.pi / 180) or 1
  return { sign = signOf(d), scale = scale, unit = unit, magnitude = math.abs(d),
           status = math.abs(d) >= floor and "ok" or "too-small" }
end

-- Set signHeading so the CORRECTED heading moves the same direction as the yawRate sensor observed
-- during the SAME rotation. The heading hold loop damps on yawRate but springs on heading error, so
-- if the two sensors disagree the position term is a NEGATIVE spring -> yaw runaway (Flight #9: they
-- were each calibrated against physics independently and ended up opposite, Q corr -0.996). Measuring
-- them together makes them consistent by construction, immune to which way the human rotates.
function M.headingSignScale(neutralHeading, sampleHeading, yawRateDuringRotation, opts)
  opts = opts or {}
  local degT = opts.degThreshold or M.HEADING_DEG
  local floor = opts.floor or M.FLOOR
  local hFloor = opts.headingFloor or M.FLOOR
  local d = sampleHeading - neutralHeading
  local unit = math.abs(d) > degT and "deg" or "rad"
  local scale = unit == "deg" and (math.pi / 180) or 1
  local headingOk = math.abs(d) >= hFloor
  local yawOk = math.abs(yawRateDuringRotation) >= floor
  -- signHeading * sign(d) must equal sign(yawRate)  =>  signHeading = sign(yawRate) * sign(d)
  local sign = signOf(yawRateDuringRotation) * signOf(d)
  return { sign = sign, scale = scale, unit = unit, magnitude = math.abs(d),
           headingOk = headingOk, yawOk = yawOk,
           status = (headingOk and yawOk) and "ok" or "too-small" }
end

function M.computeHeightOffset(groundRawAlt, baroThrusterOffset)
  return -((groundRawAlt or 0) + (baroThrusterOffset or 0))
end

function M.computeGroundThreshold(opticalOnGround, margin)
  return (opticalOnGround or 0) + (margin or 0.5)
end

return M
