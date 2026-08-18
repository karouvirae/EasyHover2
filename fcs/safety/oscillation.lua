-- Oscillation detector. Watches pitch and roll for a genuine limit cycle -- a sustained,
-- amplitude-carrying sign flip -- and latches a trip the flight loop turns into DAMPED.
--
-- Two hard-won properties (a false trip on a level climb once flew the craft off):
--   * amplitude deadband: a crossing counts ONLY when the signal swings past +deadband and
--     back past -deadband. Sub-deadband sensor dither on a level axis holds the last sign and
--     manufactures no crossings.
--   * per-axis: pitch and roll are tracked independently (trip if EITHER oscillates) -- the old
--     summed signal let one axis' noise ride on the other and parked near zero on level flight.
-- And the trip AUTO-RECOVERS: it releases once no crossing has been counted for calmTime, so a
-- transient no longer latches DAMPED forever (clearDamped() still force-resets).
local Osc = {}
Osc.__index = Osc

local function newAxis() return { lastSign = 0, changes = {} } end

function Osc.new(cfg)
  return setmetatable({
    window = cfg.window or 1.0,
    minChanges = cfg.minChanges or 6,
    deadband = cfg.deadband or 0,
    calmTime = cfg.calmTime or 1.0,
    t = 0,
    tripped = false,
    lastCross = -math.huge,
    pitch = newAxis(),
    roll = newAxis(),
  }, Osc)
end

function Osc:reset()
  self.t = 0
  self.tripped = false
  self.lastCross = -math.huge
  self.pitch = newAxis()
  self.roll = newAxis()
end

-- Count sign flips for one axis; returns true if this axis alone exceeds the threshold in-window.
function Osc:_axis(ax, v)
  local s = (v > self.deadband) and 1 or ((v < -self.deadband) and -1 or 0)
  if s ~= 0 then
    if ax.lastSign ~= 0 and s ~= ax.lastSign then
      ax.changes[#ax.changes + 1] = self.t
      self.lastCross = self.t
    end
    ax.lastSign = s
  end
  local cutoff = self.t - self.window
  while ax.changes[1] and ax.changes[1] < cutoff do table.remove(ax.changes, 1) end
  return #ax.changes >= self.minChanges
end

-- update(pitch, roll, dt) -> tripped(bool). Latches on either axis oscillating; auto-recovers
-- after calmTime with no counted crossing. Both axes are evaluated (no short-circuit).
function Osc:update(pitch, roll, dt)
  self.t = self.t + (dt > 0 and dt or 0)
  local pOver = self:_axis(self.pitch, pitch or 0)
  local rOver = self:_axis(self.roll, roll or 0)
  if pOver or rOver then
    self.tripped = true
  elseif self.tripped and (self.t - self.lastCross) >= self.calmTime then
    self.tripped = false
  end
  return self.tripped
end

return Osc
