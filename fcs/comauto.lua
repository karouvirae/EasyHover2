-- fcs/comauto.lua
-- CoM auto-trim: prereq lamp + climb/hold/capture/descend procedure. No Basalt/peripherals.
local Mixer = require("fcs.mixer.level_flight")

local M = {}

M.PREREQS = { "bind", "senscal", "span", "engine", "ground", "gndSafe", "still", "fuel", "engaged", "mode" }

local LABELS = {
  bind     = "MDB BIND",
  senscal  = "SENS CAL",
  span     = "COM SPAN",
  engine   = "ENG MASTER",
  ground   = "ON GROUND",
  gndSafe  = "GND SAFE",
  still    = "NOT MOVING",
  fuel     = "FUEL 20%",
  engaged  = "FCS ENGAGE",
  mode     = "LDG/PRE",
}

function M.label(id) return LABELS[id] or tostring(id) end

local function bound(name)
  return type(name) == "string" and name ~= ""
end

function M.missing(ctx)
  ctx = ctx or {}
  local th = ctx.thrusters or {}
  local se = ctx.sensors or {}
  if not (bound(th.FL) and bound(th.FR) and bound(th.RL) and bound(th.RR)
      and bound(se.altimeter) and bound(se.gimbal)) then
    return "bind"
  end
  local sc = ctx.senscal or {}
  if sc.signPitch == nil or sc.signHeading == nil then return "senscal" end
  local spanFwd = ctx.comSpanFwd or ctx.comSpan
  local spanRight = ctx.comSpanRight or ctx.comSpan
  if type(spanFwd) ~= "number" or spanFwd < 0.1 or type(spanRight) ~= "number" or spanRight < 0.1 then
    return "span"
  end
  if not ctx.engineOn then return "engine" end
  if ctx.onGround ~= true then return "ground" end
  if ctx.gndSafety then return "gndSafe" end
  if ctx.moving then return "still" end
  if type(ctx.fuelFrac) ~= "number" or ctx.fuelFrac < 0.20 then return "fuel" end
  if not ctx.engaged then return "engaged" end
  -- Auto-COM is a pad procedure and needs a real onGround reading, which only LDG produces
  -- (groundSense is LDG-only). So LDG is the eligible pad mode (boot default); PRECISION stays
  -- accepted for heritage but can never reach here on a live craft (it fails `ground` first).
  -- Requiring PRECISION alone deadlocked the lamp: onGround needs LDG, mode needed PRECISION.
  local mode = ctx.flightMode
  if mode ~= "PRECISION" and mode ~= "LDG" then return "mode" end
  return nil
end

function M.lamp(ctx, running)
  if running then return "blue" end
  if M.missing(ctx) then return "red" end
  return "green"
end

local P = {}
P.__index = P

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    phase = "IDLE",
    spanFwd = opts.spanFwd or opts.span or 1,
    spanRight = opts.spanRight or opts.span or 1,
    climbHeight = opts.climbHeight or 8,
    tiltLim = opts.tiltLim or 0.15,
    posLim = opts.posLim or 4,
    dwell = opts.dwell or 2.5,
    climbRate = opts.climbRate or 0.6,
    descendRate = opts.descendRate or 0.7,
    landEps = opts.landEps or 0.4,
    watchdog = opts.watchdog or 45,
    captureKi = opts.captureKi or 0.02,
    originSway = 0, originSurge = 0, originHdg = 0, baseAlt = 0,
    target = 0, elapsed = 0, held = 0, captured = nil, abortReason = nil,
  }, P)
end

function P:active()
  return self.phase == "CLIMB" or self.phase == "HOLD" or self.phase == "DESCEND"
end

function P:start(meas)
  meas = meas or {}
  self.phase = "CLIMB"
  self.elapsed = 0
  self.held = 0
  self.captured = nil
  self.abortReason = nil
  self.baseAlt = meas.altitude or 0
  self.target = self.baseAlt
  self.originSway = meas.swayPos or 0
  self.originSurge = meas.surgePos or 0
  self.originHdg = meas.heading or 0
  return true
end

function P:abort(reason)
  if self.phase == "IDLE" or self.phase == "DONE" then return end
  self.abortReason = self.abortReason or reason or "ABORT"
  if self.phase ~= "DESCEND" then self.phase = "DESCEND" end
end

local function hypot(a, b)
  return math.sqrt((a or 0) * (a or 0) + (b or 0) * (b or 0))
end

function P:tick(dt, meas, duties, loopMode)
  dt = (dt and dt > 0) and dt or 0
  meas = meas or {}
  local r = { phase = self.phase, holdStick = self:active(), done = false, abortReason = self.abortReason,
              captured = self.captured, setpoints = nil }

  if self.phase == "IDLE" or self.phase == "DONE" then
    r.done = self.phase == "DONE"
    return r
  end

  self.elapsed = self.elapsed + dt
  if loopMode == "DAMPED" then self:abort("DAMPED")
  elseif math.abs(meas.pitch or 0) > self.tiltLim or math.abs(meas.roll or 0) > self.tiltLim then
    self:abort("TILT")
  elseif hypot((meas.swayPos or 0) - self.originSway, (meas.surgePos or 0) - self.originSurge) > self.posLim then
    self:abort("POS")
  elseif self.elapsed >= self.watchdog then
    self:abort("TIME")
  end
  if self.phase == "ABORT" then
    r.phase = "ABORT"; r.abortReason = self.abortReason; r.done = true; r.holdStick = false
    return r
  end

  local top = self.baseAlt + self.climbHeight
  if self.phase == "CLIMB" then
    self.target = math.min(top, self.target + self.climbRate * dt)
    if meas.altitude then self.target = math.min(self.target, meas.altitude + 1.0) end
    if self.target >= top - 0.05 then self.phase = "HOLD"; self.held = 0 end
  elseif self.phase == "HOLD" then
    self.target = top
    local level = math.abs(meas.pitch or 0) < 0.05 and math.abs(meas.roll or 0) < 0.05
        and math.abs(meas.vSpeed or 0) < 0.3
    if level then self.held = self.held + dt else self.held = 0 end
    if self.held >= self.dwell then
      self.captured = Mixer.offsetFromDuties(duties, { spanFwd = self.spanFwd, spanRight = self.spanRight })
      self.phase = "DESCEND"
    end
  elseif self.phase == "DESCEND" then
    self.target = math.max(self.baseAlt, self.target - self.descendRate * dt)
    if meas.altitude then self.target = math.max(self.target, meas.altitude - 1.0) end
    if meas.onGround == true or (meas.altitude and meas.altitude <= self.baseAlt + self.landEps) then
      self.phase = "DONE"
    end
  end

  r.phase = self.phase
  r.captured = self.captured
  r.abortReason = self.abortReason
  r.done = self.phase == "DONE"
  r.holdStick = self:active()
  r.setpoints = {
    altitude = self.target,
    heading = self.originHdg,
    swayPos = self.originSway,
    surgePos = self.originSurge,
    pitch = 0, roll = 0,
  }
  r.captureKi = (self.phase == "HOLD") and self.captureKi or 0
  return r
end

return M
