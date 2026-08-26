-- ui/basalt/cadence.lua
-- Pure dirty-gate signature: quantized state string for render dedup.
-- No peripherals, IO, or side effects. Testable & self-contained.

local M = {}

-- Nil-safe quantizer: returns "-" for non-numbers, quantized string for numbers.
local function qn(x, mul)
  if type(x) ~= "number" then return "-" end
  return tostring(math.floor(x * mul + 0.5))
end

-- sig(state) -> quantized string of display-visible values.
-- State is a flat table with canonical keys (missing fields return "-" or "nil").
function M.sig(state)
  state = state or {}
  return table.concat({
    tostring(state.engaged), tostring(state.gndSafety), tostring(state.positionHold),
    tostring(state.mode), tostring(state.flightMode), tostring(state.trimDir), tostring(state.linkUp),
    qn(state.altitude, 10), qn(state.vSpeed, 100), qn(state.heading, 1), qn(state.loopHz, 1),
    tostring(state.engineMaster), tostring(state.feeding), tostring(state.pulses),
    state.nextFeedInMs and tostring(math.floor(state.nextFeedInMs / 1000)) or "-",
    qn(state.pumpFrac, 100), qn(state.tankFrac, 100),
    qn(state.pumpAmount, 1), qn(state.tankMb, 1),   -- raw fuel amounts (merged flight page gauges)
    qn(state.pitch, 1), qn(state.roll, 1), qn(state.sas, 10),
    qn(state.gpsAlt, 10), qn(state.tas, 10), tostring(state.gpsFixOk),
    -- PFD waypoint target cue: repaint on bearing/steer/distance/alt/name/color change.
    qn(state.target and state.target.bearing, 1), qn(state.target and state.target.relBearing, 1),
    qn(state.target and state.target.distanceH, 1), qn(state.target and state.target.altDelta, 1),
    tostring(state.target and state.target.name or "-"),
    tostring(state.target and state.target.color or "-"),
    -- Missing-FCS blink cue: repaint when it turns on/off, AND (only while stale) on every phase flip so
    -- the button outlines blink. When NOT stale the phase term is a constant "-", so a healthy link adds
    -- zero repaints (the blink is free until the FCS actually goes missing).
    tostring(state.fcsStale), (state.fcsStale and tostring(state.blinkPhase) or "-"),
    tostring(state.uiRev),
  }, "|")
end

-- gate(prev, state) -> changed, sig
-- Returns (true, sig) on first frame (prev == nil) or when sig changes.
-- Returns (false, sig) when sig is unchanged.
function M.gate(prev, state)
  local sig = M.sig(state)
  local changed = (prev ~= sig)
  return changed, sig
end

return M
