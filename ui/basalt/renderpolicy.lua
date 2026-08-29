-- ui/basalt/renderpolicy.lua
-- PURE policy table + per-panel dirty-gate signatures for the cockpit render loop. Decouples "how
-- often / on what trigger does this screen repaint" (M.policyFor) from "what counts as a visible
-- change for THIS panel" (M.sigPfd / M.sigFlight / M.sigParams) so each panel can run its own
-- cadence instead of sharing one signature (ui/basalt/cadence.lua's M.sig) across every screen.
--
-- NO Basalt/peripheral/fs/os access at module load OR inside any exported function -- everything
-- here is a pure function of its arguments, so this loads and runs clean headless with nothing
-- mounted (verified against tests/test_renderpolicy.lua).
--
-- M.policyFor(screenId, pfdMs) -> policy table:
--   { mode = "rate", ms = <number>, sig = <sig function> }  -- repaint on a timer, gated by sig
--   { mode = "event" }                                       -- repaint only on an explicit event
--     (screen nav, a button press bumping runtime.uiRev, etc.) -- no timer, no signature.
-- Screens not covered by policyFor's rate branches (config/nav/dtc/anything else) default to
-- "event" -- they don't carry a live telemetry readout, so polling them on a timer would just burn
-- cycles for nothing new to show.
local M = {}

-- Cadence constants (spec'd exact values -- ui/basalt/pages/flight.lua's merged EMC+FCS view and
-- ui/basalt/bitconfig/tuning.lua's COM-auto status live-status readout respectively).
M.FLIGHT_MS = 250
M.PARAMS_MS = 1000

-- Nil-safe quantizer, same style as ui/basalt/cadence.lua's local `qn` -- returns "-" for a
-- non-number so a still-unset/missing field never churns the signature, and rounds to the nearest
-- 1/mul so sub-quantum jitter (e.g. a 0.004 float wobble) doesn't trigger a repaint either.
local function qn(x, mul)
  if type(x) ~= "number" then return "-" end
  return tostring(math.floor(x * mul + 0.5))
end

-- ===== M.sigPfd(state): the PFD page's displayed fields only (ui/basalt/pages/pfd.lua) =====
-- Heading tape, attitude (pitch/roll), ALT/SPD readouts (baro altitude, GPS alt, TAS, SAS, GPS fix
-- quality), and the waypoint/route steering cue (target.*). Deliberately excludes fuel/engine/mode
-- fields -- a fuel-gauge tick must NEVER repaint the PFD (per-panel isolation).
function M.sigPfd(state)
  state = state or {}
  local tgt = state.target
  return table.concat({
    qn(state.pitch, 100), qn(state.roll, 100), qn(state.heading, 1),
    qn(state.altitude, 10), qn(state.gpsAlt, 10), qn(state.tas, 10), qn(state.sas, 10),
    tostring(state.gpsFixOk),
    qn(tgt and tgt.bearing, 1), qn(tgt and tgt.relBearing, 1),
    qn(tgt and tgt.distanceH, 1), qn(tgt and tgt.altDelta, 1),
    tostring(tgt and tgt.name or "-"), tostring(tgt and tgt.color or "-"),
  }, "|")
end

-- ===== M.sigFlight(state): the merged FLIGHT page's EMC+FCS regions only =====
-- (ui/basalt/regions/emc.lua's M.main gauges/ENG SW/PRIME/MASTER/FEED lights, ui/basalt/
-- regions/fcs.lua's M.main FCS/GND switches + mode chips + missing-FCS blink outline).
-- fcsStale/blinkPhase drive the missing-FCS outline blink (ui/basalt/fcslink.lua): the phase term
-- is folded to a constant "-" while the link is healthy, so a healthy link adds ZERO repaints --
-- the blink only costs anything once the FCS actually goes missing (mirrors cadence.lua's M.sig).
function M.sigFlight(state)
  state = state or {}
  local parts = {
    qn(state.pumpAmount, 1), qn(state.tankMb, 1),
    tostring(state.feeding), tostring(state.engaged), tostring(state.gndSafety),
    tostring(state.flightMode), tostring(state.engineMaster), tostring(state.pulses),
    tostring(state.fcsStale), (state.fcsStale and tostring(state.blinkPhase) or "-"),
    tostring(state.fuel), tostring(state.fuelPct), tostring(state.badFuel),
    tostring(state.fuelEst and state.fuelEst.state),
    qn(state.fuelEst and state.fuelEst.mbPerMin, 1),
    qn(state.fuelEst and state.fuelEst.secondsLeft, 1),
    tostring(state.paramsOpen or false),
  }
  if state.paramsOpen then
    parts[#parts + 1] = qn(state.tas, 10)
    parts[#parts + 1] = qn(state.loopHz, 1)
    parts[#parts + 1] = qn(state.uiLoopMs, 1)
    parts[#parts + 1] = qn(state.navLoopMs, 1)
    parts[#parts + 1] = tostring(state.gpsQuality or "-")
    parts[#parts + 1] = tostring(state.devWarn)
    parts[#parts + 1] = tostring(state.diskFcs)
    parts[#parts + 1] = tostring(state.diskNav)
  end
  return table.concat(parts, "|")
end

-- ===== M.sigParams(state): the tuning/params page's live COM-auto status only =====
-- (ui/basalt/bitconfig/tuning.lua's buildComAutoScreen: ComAuto.missing/lamp/label from engineOn/
-- onGround/gndSafety/moving(vSpeed)/fuelFrac(tankFrac)/engaged/flightMode, plus the live
-- state.comAuto.phase/captured the "reason" label and one-time span-capture read directly). uiRev
-- covers a config edit (e.g. a manual span entry) forcing a repaint outside the telemetry fields.
function M.sigParams(state)
  state = state or {}
  local ca = state.comAuto
  return table.concat({
    tostring(state.engineMaster), tostring(state.onGround), tostring(state.gndSafety),
    qn(state.vSpeed, 100), qn(state.tankFrac, 100), tostring(state.engaged), tostring(state.flightMode),
    tostring(ca and ca.phase or "-"), tostring(ca and ca.captured ~= nil),
    tostring(state.uiRev),
  }, "|")
end

-- ===== M.policyFor(screenId, pfdMs) -> policy table =====
-- pfdMs: the PFD's caller-tunable render rate (ui/basalt/bitconfig/pfd.lua's "PFD RATE" setting,
-- see cockpit-polish checkpoint) -- only meaningful for screenId=="pfd"; ignored otherwise.
local RATE_SCREENS = {
  flight = true, emc = true, fcs = true,
}

function M.policyFor(screenId, pfdMs)
  if screenId == "pfd" then
    return { mode = "rate", ms = pfdMs, sig = M.sigPfd }
  end
  if RATE_SCREENS[screenId] then
    return { mode = "rate", ms = M.FLIGHT_MS, sig = M.sigFlight }
  end
  if screenId == "tuning" then
    return { mode = "rate", ms = M.PARAMS_MS, sig = M.sigParams }
  end
  return { mode = "event" }
end

return M
