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
  local yawStatus = M.gate(diff, comm, floor, ratio)
  return { signFront = signFront, signRear = signRear, signYawRate = signOf(diff),
           swayStatus = swayStatus, yawStatus = yawStatus,
           swayOk = swayStatus == "ok", yawOk = yawStatus == "ok" }
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

function M.computeHeightOffset(groundRawAlt, baroThrusterOffset)
  return -((groundRawAlt or 0) + (baroThrusterOffset or 0))
end

function M.computeGroundThreshold(opticalOnGround, margin)
  return (opticalOnGround or 0) + (margin or 0.5)
end

return M
