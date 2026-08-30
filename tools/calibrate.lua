-- EasyHover 2 - guided sensor calibration.
-- Pure helpers here are headless-tested; the interactive run() shell (added later)
-- is in-game only. Wrapped peripherals take NO self: p.getAngles(), p.getVelocity().
local cal = require("fcs.io.calibration")
local fsx = require("fcs.io.fsx")
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
  b.signHeading = result.sign; b.compassSign = result.sign; b.headingScale = result.scale
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
local cfgspec = require("fcs.io.cfgspec")
local LEGACY_CONFIG_PATH = "/eh2_hw_config.tbl"

-- Load the FLAT senscal bindings table (cfg.signPitch, not cfg.bindings.signPitch).
-- Prefers eh2_senscal.tbl; if that file is absent AND the old combined
-- /eh2_hw_config.tbl is present, migrates the calibration out of it (read-through,
-- nothing lost). `read(filename) -> bodyStringOrNil`.
function M._loadCal(read)
  local cfg, existed, err = cfgspec.load("senscal", read)
  if err then return nil, err end
  if not existed then
    local legacyBody = read(LEGACY_CONFIG_PATH)
    if legacyBody ~= nil then
      local legacy = textutils.unserialise(legacyBody)
      if type(legacy) == "table" then
        cfg = cfgspec.merge("senscal", cfgspec.splitLegacy(legacy).senscal)
      end
    end
  end
  return cfg
end

-- Persist ONLY the calibration values (flat bindings table) to eh2_senscal.tbl.
-- `write(filename, body)`.
function M._saveCal(cfg, write) return cfgspec.save("senscal", cfg, write) end

-- Load the device-name bindings (config.sensors.<name>) the interactive shell needs to
-- wrap peripherals. Mirrors _loadCal's read-through so the terminal fallback stays
-- fully functional after the split: eh2_devbind.tbl first, else migrate out of legacy
-- /eh2_hw_config.tbl.
local function loadSensors(read)
  local cfg, existed = cfgspec.load("devbind", read)
  if not existed then
    local legacyBody = read(LEGACY_CONFIG_PATH)
    if legacyBody ~= nil then
      local legacy = textutils.unserialise(legacyBody)
      if type(legacy) == "table" then
        cfg = cfgspec.merge("devbind", cfgspec.splitLegacy(legacy).devbind)
      end
    end
  end
  return cfg.sensors
end

local realRead = fsx.read
local realWrite = fsx.writeAtomic

local function readNum(p, method) if not p then return 0 end local v = p[method](); return v or 0 end
M.readNum = readNum

-- collect a reader's samples for ~secs seconds
local function stream(readerFn, secs)
  local out = {}; local t0 = os.epoch("utc")
  repeat out[#out+1] = readerFn(); sleep(0.1) until (os.epoch("utc") - t0) / 1000 >= secs
  return out
end
-- Exposed so other guided-calibration front-ends (e.g. ui/basalt/bitconfig/senscal.lua) can reuse
-- the SAME sleep-loop sampler instead of reimplementing it. Pure delegation, no behavior change.
M.stream = stream

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
    if accept(r) then M.applyGimbal(config, axis, r); M._saveCal(config.bindings, realWrite); print("  saved") end
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
    write("  accept? (y/n): "); if read() == "y" then M.applyLateral(config, r); M._saveCal(config.bindings, realWrite); print("  saved") end
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
  if accept(r) then M.applyScalarSign(config, "signVelMedial", r.sign); M._saveCal(config.bindings, realWrite); print("  saved") end
end

-- Compute yawRate exactly as fcs/io/backend.lua does, from the live velocity sensors.
local function readYawRate(vf, vr, b)
  local vfv = (b.signVelFront or 1) * readNum(vf, "getVelocity")
  local vrv = (b.signVelRear or 1) * readNum(vr, "getVelocity")
  local base = (b.yawBaseline and b.yawBaseline ~= 0) and b.yawBaseline or 1
  return (b.signYawRate or 1) * (vfv - vrv) / base
end
M.readYawRate = readYawRate

local function stepHeading(shim, config)
  local nav = config.sensors.navTable and shim.wrap(config.sensors.navTable)
  if not nav then print("navTable not bound"); return end
  local vf = config.sensors.velFront and shim.wrap(config.sensors.velFront)
  local vr = config.sensors.velRear and shim.wrap(config.sensors.velRear)
  if not (vf and vr) then
    print("velFront/velRear not bound -- run LATERAL (2) first so heading can be")
    print("cross-checked against the yaw-rate sensor (prevents the yaw-runaway sign bug).")
    return
  end
  local b = config.bindings
  print("Face craft at reference heading, hold still, press Enter"); read()
  local n = M.average(stream(function() return readNum(nav, "getRelativeAngle") end, 1))
  print("Rotate NOSE ~90 deg to the RIGHT over ~3s -- KEEP IT MOVING, press Enter then rotate"); read()
  -- stream heading AND yawRate together during the ONE rotation, so the two are consistent by construction.
  local heads, yaws = {}, {}
  local t0 = os.epoch("utc")
  repeat
    heads[#heads + 1] = readNum(nav, "getRelativeAngle")
    yaws[#yaws + 1] = readYawRate(vf, vr, b)
    sleep(0.1)
  until (os.epoch("utc") - t0) / 1000 >= 3
  local m = heads[#heads]
  local yawPeak = M.peakByAbs(yaws)
  local r = cal.headingSignScale(n, m, yawPeak)
  print(("heading sign %d unit %s (mag %.3f, yawPeak %.3f) [%s]"):format(
    r.sign, r.unit, r.magnitude, yawPeak, r.status))
  if r.status ~= "ok" then
    print("  REJECTED -- rotate a clear ~90deg AND keep it moving so the velocity sensors register yaw.")
    return
  end
  if accept(r) then M.applyHeading(config, r); M._saveCal(config.bindings, realWrite); print("  saved (heading consistent with yawRate)") end
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
  write("  accept? (y/n): "); if read() == "y" then M.applyGround(config, off, thr); M._saveCal(config.bindings, realWrite); print("  saved") end
end

local function stepConstants(config)
  write("yawBaseline (fore/aft sensor spacing, blocks): "); local yb = tonumber(read()) or config.bindings.yawBaseline
  write("baroThrusterOffset (+ = baro above thrusters, blocks): "); local bo = tonumber(read()) or config.bindings.baroThrusterOffset
  M.applyConstants(config, yb, bo); M._saveCal(config.bindings, realWrite); print("  saved")
end

local function review(config)
  local b = config.bindings
  print("-- bindings --")
  for _, k in ipairs({ "gimbalPitchIdx","gimbalRollIdx","gimbalScale","signPitch","signRoll",
    "signVelFront","signVelRear","signVelMedial","signHeading","headingScale","signYawRate",
    "yawBaseline","heightOffset","onGroundThreshold","baroThrusterOffset" }) do
    print(("  %-18s %s"):format(k, tostring(b[k])))
  end
  M._saveCal(config.bindings, realWrite); print("written to " .. cfgspec.FILES.senscal)
end

function M.run()
  local shim = require("fcs.io.shim")
  local bindings, calErr = M._loadCal(realRead)
  if calErr then print("corrupt " .. cfgspec.FILES.senscal .. ": " .. tostring(calErr)); return end
  local config = { sensors = loadSensors(realRead), bindings = bindings }
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
