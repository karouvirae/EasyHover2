-- ui/fuelrate.lua -- adaptive fuel drain-rate + time-to-empty from main-tank mB samples.
-- Pure (no peripheral/Basalt). Two-layer smoother: a steady slow(~60s) baseline that SNAPS toward
-- a fast(~10s) rate the more they diverge -- calm at steady consumption, reacts within ~2-3 samples
-- to a hover->cruise punch or throttle chop, then re-settles as the slow window ages out. Positive
-- rate = draining. UI-side only (rides the existing 3s tank poll).
local M = {}
M.__index = M
local DEFAULTS = { slowWindowS = 60, fastWindowS = 10, sensitivity = 300, idleEps = 20, refuelEps = 20, maxSamples = 30 }

function M.new(cfg)
  cfg = cfg or {}
  local self = setmetatable({ samples = {}, cfg = {} }, M)
  for k, v in pairs(DEFAULTS) do self.cfg[k] = cfg[k] or v end
  return self
end

function M:push(mb, tMs)
  if type(mb) ~= "number" or type(tMs) ~= "number" then return end
  local s = self.samples
  s[#s + 1] = { mb = mb, t = tMs }
  while #s > self.cfg.maxSamples do table.remove(s, 1) end
end

-- mB/min over ~windowS: newest vs the oldest sample within the window (or s[1] if the ring is
-- shorter). Positive = draining. nil on <2 samples or zero span.
function M:_rateOver(windowS)
  local s, n = self.samples, #self.samples
  if n < 2 then return nil end
  local newest = s[n]
  local limit = windowS * 1000
  local old = s[1]
  for i = 1, n - 1 do
    if (newest.t - s[i].t) <= limit then old = s[i]; break end
  end
  local dtMs = newest.t - old.t
  if dtMs <= 0 then return nil end
  return (old.mb - newest.mb) / dtMs * 60000
end

function M:read()
  local s, n = self.samples, #self.samples
  if n < 2 then return { state = "unknown", mbPerMin = 0, secondsLeft = nil } end
  local slow = self:_rateOver(self.cfg.slowWindowS)
  local fast = self:_rateOver(self.cfg.fastWindowS)
  slow = slow or fast or 0
  fast = fast or slow
  local sens = self.cfg.sensitivity
  local w = (sens > 0) and math.min(1, math.abs(fast - slow) / sens) or 1
  local displayed = slow + w * (fast - slow)            -- signed mB/min
  if displayed < -self.cfg.refuelEps then
    return { state = "refuel", mbPerMin = 0, secondsLeft = nil }
  end
  local mbPerMin = math.max(0, displayed)
  if mbPerMin <= self.cfg.idleEps then
    return { state = "idle", mbPerMin = 0, secondsLeft = nil }
  end
  local curMb = s[n].mb
  local secondsLeft = (type(curMb) == "number" and curMb > 0) and (curMb / (mbPerMin / 60)) or nil
  return { state = "drain", mbPerMin = mbPerMin, secondsLeft = secondsLeft }
end

return M
