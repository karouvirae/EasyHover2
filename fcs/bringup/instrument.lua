-- Pure instrumentation for the hover bring-up runner: CSV rows + an incremental summary
-- (no in-memory row hoarding). No CC dependencies.
local frame = require("fcs.frame")
local M = {}

local DUTY_IDS = {}
for _, id in ipairs(frame.LIFT)    do DUTY_IDS[#DUTY_IDS+1] = id end
for _, id in ipairs(frame.LATERAL) do DUTY_IDS[#DUTY_IDS+1] = id end
for _, id in ipairs(frame.MAIN)    do DUTY_IDS[#DUTY_IDS+1] = id end
for _, id in ipairs(frame.FRONTAL) do DUTY_IDS[#DUTY_IDS+1] = id end

local SCALAR_COLS = { "t","dt_ms","hz","phase","mode","sp_alt","alt","vSpeed","pitch","roll",
  "heading","yawRate","swayVel","surgeVel","swayPos","surgePos","onGround","heave",
  "dPitch","dRoll","dYaw","dSway","dSurge" }

function M.header()
  local cols = {}
  for _, c in ipairs(SCALAR_COLS) do cols[#cols+1] = c end
  for _, id in ipairs(DUTY_IDS) do cols[#cols+1] = id end
  return table.concat(cols, ",")
end

local function num(v) return string.format("%.4f", v or 0) end

function M.formatRow(s)
  local dt = s.dt or 0
  local vals = {
    num(s.t), num(dt*1000), num(dt > 0 and 1/dt or 0), tostring(s.phase or ""),
    tostring(s.mode or ""), num(s.sp_alt), num(s.alt), num(s.vSpeed), num(s.pitch),
    num(s.roll), num(s.heading), num(s.yawRate), num(s.swayVel), num(s.surgeVel),
    num(s.swayPos), num(s.surgePos), s.onGround and "1" or "0", num(s.heave),
    num(s.dPitch), num(s.dRoll), num(s.dYaw), num(s.dSway), num(s.dSurge),
  }
  local d = s.duties or {}
  for _, id in ipairs(DUTY_IDS) do vals[#vals+1] = num(d[id]) end
  return table.concat(vals, ",")
end

local Summary = {}
Summary.__index = Summary
M.Summary = Summary

function Summary.new()
  return setmetatable({
    n = 0, tFirst = nil, tLast = 0,
    hzMin = math.huge, hzMax = 0, hzSum = 0, hzN = 0,
    heading0 = nil, headingDrift = 0,
    swayMin = math.huge, swayMax = -math.huge, surgeMin = math.huge, surgeMax = -math.huge,
    maxPitch = 0, maxRoll = 0, peakClimbV = 0, peakDescentV = 0,
    holdAltMin = math.huge, holdAltMax = -math.huge,
    perr = { CLIMB={sum=0,max=0,n=0}, HOLD={sum=0,max=0,n=0}, DESCEND={sum=0,max=0,n=0} },
    damped = false, touchdownV = nil, lastPhase = nil,
  }, Summary)
end

function Summary:add(s)
  self.n = self.n + 1
  if self.tFirst == nil then self.tFirst = s.t or 0 end
  self.tLast = s.t or self.tLast
  local dt = s.dt or 0
  if dt > 0 then
    local hz = 1/dt
    if hz < self.hzMin then self.hzMin = hz end
    if hz > self.hzMax then self.hzMax = hz end
    self.hzSum = self.hzSum + hz; self.hzN = self.hzN + 1
  end
  if self.heading0 == nil then self.heading0 = s.heading or 0 end
  local hd = math.abs((s.heading or 0) - self.heading0)
  if hd > self.headingDrift then self.headingDrift = hd end
  local sp, su = s.swayPos or 0, s.surgePos or 0
  if sp < self.swayMin then self.swayMin = sp end
  if sp > self.swayMax then self.swayMax = sp end
  if su < self.surgeMin then self.surgeMin = su end
  if su > self.surgeMax then self.surgeMax = su end
  if math.abs(s.pitch or 0) > self.maxPitch then self.maxPitch = math.abs(s.pitch or 0) end
  if math.abs(s.roll or 0) > self.maxRoll then self.maxRoll = math.abs(s.roll or 0) end
  local v = s.vSpeed or 0
  if v > self.peakClimbV then self.peakClimbV = v end
  if v < self.peakDescentV then self.peakDescentV = v end
  if s.mode == "DAMPED" then self.damped = true end
  if s.phase == "HOLD" then
    local a = s.alt or 0
    if a < self.holdAltMin then self.holdAltMin = a end
    if a > self.holdAltMax then self.holdAltMax = a end
  end
  local pe = self.perr[s.phase]
  if pe then
    local e = math.abs((s.alt or 0) - (s.sp_alt or 0))
    pe.sum = pe.sum + e; pe.n = pe.n + 1
    if e > pe.max then pe.max = e end
  end
  if s.phase == "LANDED" and self.lastPhase ~= "LANDED" then self.touchdownV = v end
  self.lastPhase = s.phase
end

local function mean(sum, n) return n > 0 and (sum / n) or 0 end

function Summary:finalize()
  local dur = (self.tFirst ~= nil) and (self.tLast - self.tFirst) or 0
  local bob = (self.holdAltMax >= self.holdAltMin) and (self.holdAltMax - self.holdAltMin) or 0
  local function perrOf(k) local p = self.perr[k]; return { mean = mean(p.sum, p.n), max = p.max } end
  return {
    samples = self.n, duration = dur,
    hzMin = self.hzMin == math.huge and 0 or self.hzMin, hzMax = self.hzMax,
    hzAvg = mean(self.hzSum, self.hzN),
    bobAmplitude = bob, peakClimbV = self.peakClimbV, peakDescentV = self.peakDescentV,
    maxPitch = self.maxPitch, maxRoll = self.maxRoll,
    swayRange = (self.swayMax >= self.swayMin) and (self.swayMax - self.swayMin) or 0,
    surgeRange = (self.surgeMax >= self.surgeMin) and (self.surgeMax - self.surgeMin) or 0,
    headingDrift = self.headingDrift, touchdownV = self.touchdownV or 0, damped = self.damped,
    errClimb = perrOf("CLIMB"), errHold = perrOf("HOLD"), errDescend = perrOf("DESCEND"),
  }
end

function M.formatSummary(m)
  local lines = {
    "# EasyHover 2 hover bring-up log",
    "samples: " .. m.samples,
    string.format("duration_s: %.2f", m.duration),
    string.format("loop_hz: min %.2f avg %.2f max %.2f", m.hzMin, m.hzAvg, m.hzMax),
    string.format("hold_bob_amplitude_blocks: %.3f", m.bobAmplitude),
    string.format("peak_climb_vSpeed: %.3f", m.peakClimbV),
    string.format("peak_descent_vSpeed: %.3f", m.peakDescentV),
    string.format("touchdown_vSpeed: %.3f", m.touchdownV),
    string.format("max_pitch: %.4f  max_roll: %.4f", m.maxPitch, m.maxRoll),
    string.format("horizontal_drift_blocks: sway %.3f  surge %.3f", m.swayRange, m.surgeRange),
    string.format("heading_drift: %.4f", m.headingDrift),
    string.format("alt_err_climb: mean %.3f max %.3f", m.errClimb.mean, m.errClimb.max),
    string.format("alt_err_hold: mean %.3f max %.3f", m.errHold.mean, m.errHold.max),
    string.format("alt_err_descend: mean %.3f max %.3f", m.errDescend.mean, m.errDescend.max),
    "damped_tripped: " .. (m.damped and "YES" or "no"),
  }
  return table.concat(lines, "\n")
end

return M
