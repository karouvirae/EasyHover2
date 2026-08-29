-- tests/test_renderpolicy.lua
-- ui/basalt/renderpolicy.lua: PURE policy table (per-screen render mode/cadence) + per-panel
-- signature functions. No Basalt/peripheral access -- this module is required directly, headless.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local RP = require("ui.basalt.renderpolicy")

-- ===== policyFor =====

t.test("policyFor pfd: rate mode, ms follows the pfdMs argument, sig = M.sigPfd", function()
  local p1 = RP.policyFor("pfd", 500)
  t.eq(p1.mode, "rate", "pfd mode")
  t.eq(p1.ms, 500, "pfd ms follows caller-supplied pfdMs")
  t.eq(p1.sig, RP.sigPfd, "pfd sig is M.sigPfd")

  local p2 = RP.policyFor("pfd", 250)
  t.eq(p2.ms, 250, "pfd ms follows a different pfdMs")
end)

t.test("policyFor flight/emc/fcs: rate mode, ms = M.FLIGHT_MS, sig = M.sigFlight", function()
  for _, id in ipairs({ "flight", "emc", "fcs" }) do
    local p = RP.policyFor(id)
    t.eq(p.mode, "rate", id .. " mode")
    t.eq(p.ms, RP.FLIGHT_MS, id .. " ms == M.FLIGHT_MS")
    t.eq(p.sig, RP.sigFlight, id .. " sig is M.sigFlight")
  end
end)

t.test("policyFor tuning: rate mode, ms = M.PARAMS_MS, sig = M.sigParams", function()
  local p = RP.policyFor("tuning")
  t.eq(p.mode, "rate", "tuning mode")
  t.eq(p.ms, RP.PARAMS_MS, "tuning ms == M.PARAMS_MS")
  t.eq(p.sig, RP.sigParams, "tuning sig is M.sigParams")
end)

t.test("policyFor config/nav/dtc/unknown: event mode, no ms/sig", function()
  for _, id in ipairs({ "config", "nav", "dtc", "unknown", "somethingElse" }) do
    local p = RP.policyFor(id)
    t.eq(p.mode, "event", id .. " mode")
    t.eq(p.ms, nil, id .. " has no ms")
    t.eq(p.sig, nil, id .. " has no sig")
  end
end)

t.test("M.FLIGHT_MS and M.PARAMS_MS have the spec'd exact values", function()
  t.eq(RP.FLIGHT_MS, 250, "FLIGHT_MS")
  t.eq(RP.PARAMS_MS, 1000, "PARAMS_MS")
end)

-- ===== sigFlight: masterMode/trimDir must be signature-tracked (no-optimistic-UI repaint) =====

t.test("sigFlight changes when masterMode flips CPL->DCPL (master button must repaint)", function()
  local a = RP.sigFlight({ flightMode = "PRECISION", masterMode = "CPL" })
  local b = RP.sigFlight({ flightMode = "PRECISION", masterMode = "DCPL" })
  t.truthy(a ~= b, "masterMode flip moves sigFlight")
end)

t.test("sigFlight changes when trimDir flips (TRIM button must repaint)", function()
  local a = RP.sigFlight({ masterMode = "CPL", trimDir = -1 })
  local b = RP.sigFlight({ masterMode = "CPL", trimDir = 1 })
  t.truthy(a ~= b, "trimDir flip moves sigFlight")
end)

-- ===== sigFlight: blink-fold rule =====

t.test("sigFlight folds blinkPhase to a constant when healthy (fcsStale=false)", function()
  local a = RP.sigFlight({ fcsStale = false, blinkPhase = 0 })
  local b = RP.sigFlight({ fcsStale = false, blinkPhase = 1 })
  t.eq(a, b, "healthy link: phase flip is inert in sigFlight")
end)

t.test("sigFlight changes with blinkPhase when stale (fcsStale=true)", function()
  local a = RP.sigFlight({ fcsStale = true, blinkPhase = 0 })
  local b = RP.sigFlight({ fcsStale = true, blinkPhase = 1 })
  t.truthy(a ~= b, "stale link: phase flip changes sigFlight")
end)

t.test("sigFlight: going stale at all is a change", function()
  local a = RP.sigFlight({ fcsStale = false, blinkPhase = 0 })
  local b = RP.sigFlight({ fcsStale = true, blinkPhase = 0 })
  t.truthy(a ~= b, "stale toggling on changes sigFlight")
end)

-- ===== sigFlight: fuel fields must be signature-tracked (a fuel-only telemetry change must repaint) =====

t.test("sigFlight changes when badFuel flips false->true", function()
  local base = { fuel = "Ethanol", fuelPct = 100, badFuel = false }
  local a = RP.sigFlight(base)
  local b = RP.sigFlight({ fuel = "Ethanol", fuelPct = 100, badFuel = true })
  t.truthy(a ~= b, "badFuel flip moves sigFlight")
end)

t.test("sigFlight changes when fuelPct changes", function()
  local base = { fuel = "Ethanol", fuelPct = 100, badFuel = false }
  local a = RP.sigFlight(base)
  local b = RP.sigFlight({ fuel = "Ethanol", fuelPct = 55, badFuel = false })
  t.truthy(a ~= b, "fuelPct change moves sigFlight")
end)

t.test("sigFlight is stable when nothing relevant changed, including fuel fields held constant", function()
  local a = RP.sigFlight({ fuel = "Ethanol", fuelPct = 100, badFuel = false, pumpAmount = 100 })
  local b = RP.sigFlight({ fuel = "Ethanol", fuelPct = 100, badFuel = false, pumpAmount = 100 })
  t.eq(a, b, "identical state -> identical sigFlight")
end)

t.test("sigFlight reacts to fuelEst change", function()
  local base = { fuelEst = { state="drain", mbPerMin=450, secondsLeft=1080 } }
  local a = RP.sigFlight(base)
  local b = RP.sigFlight({ fuelEst = { state="drain", mbPerMin=900, secondsLeft=540 } })
  local c = RP.sigFlight({ fuelEst = { state="idle", mbPerMin=0 } })
  t.truthy(a ~= b, "rate change dirties the gate")
  t.truthy(a ~= c, "state change dirties the gate")
  t.eq(RP.sigFlight(base), a, "stable when unchanged")
end)

t.test("sigFlight ignores tas/loopHz while PARAMS closed; includes them when open", function()
  local a = RP.sigFlight({ tas = 1, loopHz = 10 })
  local b = RP.sigFlight({ tas = 99, loopHz = 2 })
  t.eq(a, b, "PARAMS-closed GPS/loop must not repaint FLIGHT")
  local c = RP.sigFlight({ paramsOpen = true, tas = 1, loopHz = 10 })
  local d = RP.sigFlight({ paramsOpen = true, tas = 99, loopHz = 10 })
  t.truthy(c ~= d, "PARAMS-open TAS change moves sigFlight")
  local e = RP.sigFlight({ paramsOpen = false })
  local f = RP.sigFlight({ paramsOpen = true })
  t.truthy(e ~= f, "opening PARAMS moves sigFlight")
end)

-- ===== per-panel isolation =====

t.test("sigPfd changes when pitch changes but NOT when a fuel field changes", function()
  local base = { pitch = 0.1, roll = 0, heading = 90 }
  local s0 = RP.sigPfd(base)
  local sPitch = RP.sigPfd({ pitch = 0.5, roll = 0, heading = 90 })
  t.truthy(s0 ~= sPitch, "pitch change moves sigPfd")

  local sFuel = RP.sigPfd({ pitch = 0.1, roll = 0, heading = 90, pumpAmount = 999, tankMb = 9999 })
  t.eq(s0, sFuel, "fuel field change does NOT move sigPfd")
end)

t.test("sigFlight changes when pumpAmount changes but NOT when pitch changes", function()
  local base = { pumpAmount = 100, tankMb = 4200, engaged = true }
  local s0 = RP.sigFlight(base)
  local sPump = RP.sigFlight({ pumpAmount = 99, tankMb = 4200, engaged = true })
  t.truthy(s0 ~= sPump, "pumpAmount change moves sigFlight")

  local sPitch = RP.sigFlight({ pumpAmount = 100, tankMb = 4200, engaged = true, pitch = 0.9, roll = 0.4 })
  t.eq(s0, sPitch, "pitch/roll change does NOT move sigFlight")
end)

t.test("sigParams changes when tankFrac changes but NOT when pitch changes", function()
  local base = { engineMaster = true, onGround = false, gndSafety = false, vSpeed = 0, tankFrac = 0.5, engaged = true, flightMode = "MAN" }
  local s0 = RP.sigParams(base)
  local sTank = RP.sigParams({ engineMaster = true, onGround = false, gndSafety = false, vSpeed = 0, tankFrac = 0.4, engaged = true, flightMode = "MAN" })
  t.truthy(s0 ~= sTank, "tankFrac change moves sigParams")

  local sPitch = RP.sigParams({ engineMaster = true, onGround = false, gndSafety = false, vSpeed = 0, tankFrac = 0.5, engaged = true, flightMode = "MAN", pitch = 1.0 })
  t.eq(s0, sPitch, "pitch change does NOT move sigParams")
end)

-- ===== sigParams: covers the tuning/comauto screen's live COM-auto fields, and uiRev =====

t.test("sigParams covers engineMaster/onGround/gndSafety/vSpeed/tankFrac/engaged/flightMode", function()
  local base = { engineMaster = false, onGround = true, gndSafety = true, vSpeed = 0, tankFrac = 0.9, engaged = false, flightMode = "PRECISION" }
  local s0 = RP.sigParams(base)
  local function changed(overrides)
    local s = {}
    for k, v in pairs(base) do s[k] = v end
    for k, v in pairs(overrides) do s[k] = v end
    return RP.sigParams(s) ~= s0
  end
  t.truthy(changed({ engineMaster = true }), "engineMaster")
  t.truthy(changed({ onGround = false }), "onGround")
  t.truthy(changed({ gndSafety = false }), "gndSafety")
  t.truthy(changed({ vSpeed = 5 }), "vSpeed")
  t.truthy(changed({ tankFrac = 0.1 }), "tankFrac")
  t.truthy(changed({ engaged = true }), "engaged")
  t.truthy(changed({ flightMode = "CRUISE" }), "flightMode")
end)

t.test("sigParams reflects uiRev (a config edit forces a repaint)", function()
  local a = RP.sigParams({ uiRev = 0 })
  local b = RP.sigParams({ uiRev = 1 })
  t.truthy(a ~= b, "uiRev change moves sigParams")
end)

-- ===== nil-safety (headless / empty-state boot) =====

t.test("all three sig functions tolerate a nil or empty state (no error, stable string)", function()
  t.truthy(RP.sigPfd(nil), "sigPfd(nil)")
  t.truthy(RP.sigFlight(nil), "sigFlight(nil)")
  t.truthy(RP.sigParams(nil), "sigParams(nil)")
  t.eq(RP.sigPfd({}), RP.sigPfd({}), "sigPfd({}) stable")
  t.eq(RP.sigFlight({}), RP.sigFlight({}), "sigFlight({}) stable")
  t.eq(RP.sigParams({}), RP.sigParams({}), "sigParams({}) stable")
end)
