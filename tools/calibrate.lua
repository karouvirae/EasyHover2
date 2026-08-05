-- EasyHover 2 - guided sensor calibration.
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

-- ---- interactive shell (in-game only) ----
local hwconfig = require("fcs.io.hwconfig")
local CONFIG_PATH = "/eh2_hw_config.tbl"

local function loadConfig()
  local saved
  if fs.exists(CONFIG_PATH) then
    local f = fs.open(CONFIG_PATH, "r"); saved = textutils.unserialise(f.readAll() or ""); f.close()
  end
  return hwconfig.merge(saved or {}, hwconfig.defaults())
end
local function saveConfig(c)
  local tmp = CONFIG_PATH .. ".tmp"
  local f = fs.open(tmp, "w"); f.write(textutils.serialise(c)); f.close()
  if fs.exists(CONFIG_PATH) then fs.delete(CONFIG_PATH) end
  fs.move(tmp, CONFIG_PATH)
end

local function readNum(p, method) if not p then return 0 end local v = p[method](); return v or 0 end

-- collect a reader's samples for ~secs seconds
local function stream(readerFn, secs)
  local out = {}; local t0 = os.epoch("utc")
  repeat out[#out+1] = readerFn(); sleep(0.1) until (os.epoch("utc") - t0) / 1000 >= secs
  return out
end

local function accept(result)
  print(("  status %s"):format(result.status or "ok"))
  if result.status and result.status ~= "ok" then
    print("  REJECTED (" .. result.status .. ") - redo bigger/cleaner"); return false
  end
  write("  accept? (y/n): "); return read() == "y"
end

local function stepAttitude(shim, config)
  local gname = config.sensors.gimbal
  local gim = gname and shim.wrap(gname)
  if not gim then print("no gimbal bound"); return end
  local function avgAngles(secs)
    local ss = stream(function() return gim.getAngles() or {0, 0} end, secs)
    local a, b = {}, {}
    for i, s in ipairs(ss) do a[i] = s[1] or 0; b[i] = s[2] or 0 end
    return { M.average(a), M.average(b) }
  end
  for _, axis in ipairs({ "pitch", "roll" }) do
    local prompt = axis == "pitch" and "Tilt NOSE UP ~20 deg and HOLD" or "Roll RIGHT WING DOWN ~20 deg and HOLD"
    print("Hold craft LEVEL, press Enter for neutral"); read(); local n = avgAngles(1)
    print(prompt .. ", press Enter"); read(); local m = avgAngles(1)
    local r = cal.classifyGimbalAxis(n, m)
    print(("%s -> idx %d sign %d unit %s (%.3f vs %.3f)"):format(axis, r.idx, r.sign, r.unit, r.dominant, r.runnerUp))
    if accept(r) then M.applyGimbal(config, axis, r); saveConfig(config); print("  saved") end
  end
end

local function stepLateral(shim, config)
  local vfname, vrname = config.sensors.velFront, config.sensors.velRear
  local vf, vr = vfname and shim.wrap(vfname), vrname and shim.wrap(vrname)
  if not (vf and vr) then print("velFront/velRear not bound"); return end
  local nF, nR = readNum(vf, "getVelocity"), readNum(vr, "getVelocity")
  local function pair() return { front = readNum(vf, "getVelocity"), rear = readNum(vr, "getVelocity") } end
  local function peak(samples, proj)
    local vals = {}
    for i, s in ipairs(samples) do vals[i] = proj(s.front - nF, s.rear - nR) end
    return samples[M.argmaxAbs(vals)] or { front = nF, rear = nR }
  end
  print("SHOVE craft to its RIGHT, press Enter then shove for 3s"); read()
  local sway = peak(stream(pair, 3), function(df, dr) return df + dr end)
  print("YAW nose to the RIGHT, press Enter then yaw for 3s"); read()
  local yaw = peak(stream(pair, 3), function(df, dr) return df - dr end)
  local r = cal.classifyLateralPair({ front = nF, rear = nR }, sway, yaw)
  print(("front %d rear %d yawRate %d (diff %.2f)  sway[%s] yaw[%s]"):format(
    r.signFront, r.signRear, r.signYawRate, r.yawDiff or 0, r.swayStatus, r.yawStatus))
  if r.swayOk and r.yawOk then
    write("  accept? (y/n): "); if read() == "y" then M.applyLateral(config, r); saveConfig(config); print("  saved") end
  else print("  REJECTED - sway needs a clean sideways shove; yaw needs a clearer rotation") end
end

local function stepSurge(shim, config)
  local vmname = config.sensors.velMedial
  local vm = vmname and shim.wrap(vmname)
  if not vm then print("velMedial not bound"); return end
  local n = readNum(vm, "getVelocity")
  print("SHOVE craft FORWARD, press Enter then shove for 3s"); read()
  local peakV = M.peakByAbs(stream(function() return readNum(vm, "getVelocity") - n end, 3))
  local r = cal.classifyScalarSign(0, peakV)
  print(("surge sign %d (mag %.3f)"):format(r.sign, r.magnitude))
  if accept(r) then M.applyScalarSign(config, "signVelMedial", r.sign); saveConfig(config); print("  saved") end
end

local function stepHeading(shim, config)
  local navname = config.sensors.navTable
  local nav = navname and shim.wrap(navname)
  if not nav then print("navTable not bound"); return end
  print("Face craft at reference heading, press Enter for neutral"); read()
  local n = M.average(stream(function() return readNum(nav, "getRelativeAngle") end, 1))
  print("Rotate NOSE ~90 deg to the RIGHT and HOLD, press Enter"); read()
  local m = M.average(stream(function() return readNum(nav, "getRelativeAngle") end, 1))
  local r = cal.detectHeadingScale(n, m)
  print(("heading sign %d unit %s (mag %.3f)"):format(r.sign, r.unit, r.magnitude))
  if accept(r) then M.applyHeading(config, r); saveConfig(config); print("  saved") end
end

local function stepGround(shim, config)
  local altname, optname = config.sensors.altimeter, config.sensors.downOptical
  local alt, opt = altname and shim.wrap(altname), optname and shim.wrap(optname)
  if not (alt and opt) then print("altimeter/downOptical not bound"); return end
  print("Set craft ON THE GROUND at rest, press Enter"); read()
  local rawAlt = M.average(stream(function() return readNum(alt, "getHeight") end, 1))
  local optD = M.average(stream(function() return readNum(opt, "getDistance") end, 1))
  local off = cal.computeHeightOffset(rawAlt, config.bindings.baroThrusterOffset or 0)
  local thr = cal.computeGroundThreshold(optD)
  print(("heightOffset %.3f  onGroundThreshold %.3f"):format(off, thr))
  write("  accept? (y/n): "); if read() == "y" then M.applyGround(config, off, thr); saveConfig(config); print("  saved") end
end

local function stepConstants(config)
  write("yawBaseline (fore/aft sensor spacing, blocks): "); local yb = tonumber(read()) or config.bindings.yawBaseline
  write("baroThrusterOffset (+ = baro above thrusters, blocks): "); local bo = tonumber(read()) or config.bindings.baroThrusterOffset
  M.applyConstants(config, yb, bo); saveConfig(config); print("  saved")
end

local function review(config)
  local b = config.bindings
  print("-- bindings --")
  for _, k in ipairs({ "gimbalPitchIdx","gimbalRollIdx","gimbalScale","signPitch","signRoll",
    "signVelFront","signVelRear","signVelMedial","signHeading","headingScale","signYawRate",
    "yawBaseline","heightOffset","onGroundThreshold","baroThrusterOffset" }) do
    print(("  %-18s %s"):format(k, tostring(b[k])))
  end
  saveConfig(config); print("written to " .. CONFIG_PATH)
end

function M.run()
  local shim = require("fcs.io.shim")
  local config = loadConfig()
  while true do
    print("\n== EH2 CALIBRATE == 1 attitude 2 lateral 3 surge 4 heading 5 ground 6 constants 7 review q quit")
    local ch = read()
    if ch == "1" then stepAttitude(shim, config)
    elseif ch == "2" then stepLateral(shim, config)
    elseif ch == "3" then stepSurge(shim, config)
    elseif ch == "4" then stepHeading(shim, config)
    elseif ch == "5" then stepGround(shim, config)
    elseif ch == "6" then stepConstants(config)
    elseif ch == "7" then review(config)
    elseif ch == "q" then return end
  end
end

return M
