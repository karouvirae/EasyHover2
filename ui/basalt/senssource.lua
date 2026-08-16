-- ui/basalt/senssource.lua
-- Resolves the ACTIVE PFD attitude calibration + device names, and reads the wrapped sensors.
-- FCS source = the UI PC's own eh2_senscal.tbl (cal) + eh2_devbind.tbl (names), loaded via
-- fcs.io.cfgspec (LOCAL files -- NOT cfgsync). SELF source = config.sens.self. OFF = nothing.
-- The INACTIVE source is never touched. No peripheral/Basalt access at load; wrap/read are injected.
local cfgspec      = require("fcs.io.cfgspec")
local sensread     = require("ui.basalt.instruments.sensread")
local calibration  = require("fcs.io.calibration")

local M = {}

function M.resolve(sensCfg, readFn)
  sensCfg = sensCfg or {}
  local source = sensCfg.source or "FCS"
  if source == "OFF" then return { source = "OFF" } end

  local cal, calExisted
  if source == "SELF" then
    cal, calExisted = sensCfg.self or {}, sensCfg.self ~= nil
  else -- FCS
    cal, calExisted = cfgspec.load("senscal", readFn)
  end

  local bind, bindExisted = cfgspec.load("devbind", readFn)
  return { source = source, cal = cal, sensors = bind.sensors or {},
           calExisted = calExisted, bindExisted = bindExisted }
end

function M.readAttitude(cal, sensors, wrapFn)
  sensors = sensors or {}
  if not sensors.gimbal or not sensors.velMedial then return nil end
  local g = wrapFn(sensors.gimbal)
  local v = wrapFn(sensors.velMedial)
  if not g or not v then return nil end
  local okA, angles = pcall(function() return g.getAngles() end)
  local okV, vel = pcall(function() return v.getVelocity() end)
  local pitch, roll = sensread.attitude(okA and angles or nil, cal)
  local sas = sensread.surge(okV and vel or nil, cal)
  return { pitch = pitch, roll = roll, sas = sas }
end

function M.selfSteps()
  return {
    { id = "level",     label = "Level",       prompt = "Hold the craft LEVEL, then CAPTURE." },
    { id = "pitchFwd",  label = "Pitch fwd",   prompt = "Pitch the NOSE DOWN, then CAPTURE." },
    { id = "rollRight", label = "Roll right",  prompt = "Roll RIGHT wing down, then CAPTURE." },
    { id = "surgeFwd",  label = "Surge fwd",   prompt = "Move FORWARD steadily, then CAPTURE." },
  }
end

function M.selfApply(s)
  local pitch = calibration.classifyGimbalAxis(s.level.angles, s.pitchFwd.angles)
  local roll  = calibration.classifyGimbalAxis(s.level.angles, s.rollRight.angles)
  local surge = calibration.classifyScalarSign(s.level.vel, s.surgeFwd.vel)
  return {
    gimbalPitchIdx = pitch.idx, signPitch = pitch.sign, gimbalScale = pitch.scale,
    gimbalRollIdx  = roll.idx,  signRoll  = roll.sign,
    signVelMedial  = surge.sign,
  }
end

return M
