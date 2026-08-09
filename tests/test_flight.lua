-- tests/test_flight.lua
local t = require("tests.framework")
local Flight = require("fcs.runtime.flight")
local Pilot = require("fcs.input.pilot")

-- Fake loop records arm/setpoints/cycle without needing real control.
local function fakeLoop()
  local L = { armed = false, sp = nil, cycles = 0, mode = "NORMAL", cleared = false }
  function L:arm(b) self.armed = b and true or false end
  function L:setpoints(x) self.sp = x end
  function L:clearDamped() self.cleared = true; self.mode = "NORMAL" end
  function L:getMode() return self.mode end
  function L:cycle(dt, m) self.cycles = self.cycles + 1
    return { mode = self.mode, m = m, demands = nil, duties = nil } end
  return L
end
local CFG = { headingRate=0.6, climbRate=0.8, leadCapVert=3, cruiseSpeed=1, maxLead=4 }
local function meas() return { altitude=10, heading=0, swayPos=0, surgePos=0,
  vSpeed=0, yawRate=0, swayVel=0, surgeVel=0, pitch=0, roll=0, onGround=false } end

t.test("boot state is safe: disengaged, gndSafety on", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  t.eq(f.engaged, false); t.eq(f.gndSafety, true)
end)

t.test("engage is gated by gndSafety", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  t.eq(f:handleCommand({ k = "engage" }), false, "blocked while gndSafety on")
  t.eq(L.armed, false, "loop not armed")
  t.truthy(f:handleCommand({ k = "gndSafety", on = false }), "safety off")
  t.truthy(f:handleCommand({ k = "engage" }), "engage honored")
  t.eq(f.engaged, true, "engaged")
  f:step(0.1, {}, meas())                    -- meas() is airborne (onGround=false) => arms in step
  t.eq(L.armed, true, "loop armed once stepped airborne")
end)

t.test("engage resets pilot setpoints to current state on next step", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  f:step(0.1, {}, meas())
  t.near(L.sp.altitude, 10, 1e-9, "seeded to current altitude")
end)

t.test("disengage disarms and clears position hold", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  f:handleCommand({ k = "positionHold", on = true })
  f:handleCommand({ k = "disengage" })
  t.eq(L.armed, false); t.eq(f.positionHold, false)
end)

t.test("clearDamped forwards to the loop", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f:handleCommand({ k = "clearDamped" })
  t.truthy(L.cleared, "loop cleared")
end)

-- ---- ground-idle (engaged-but-parked) ----
local function groundMeas(o) o = o or {}
  return { altitude=10, heading=0, swayPos=0, surgePos=0, pitch=0, roll=0, yawRate=0,
           vSpeed=o.vSpeed or 0, swayVel=o.swayVel or 0, surgeVel=o.surgeVel or 0,
           onGround=(o.onGround==nil) and true or o.onGround } end
local function engagedFlight(L)
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  return f
end

t.test("parked: engaged + on-ground + at rest + no climb => loop disarmed (zero thrust)", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, {}, groundMeas())
  t.eq(L.armed, false, "parked craft => loop disarmed")
end)

t.test("climb un-parks: engaged + on-ground + climb held => loop armed", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, { up = true }, groundMeas())
  t.eq(L.armed, true, "climb intent arms for liftoff")
end)

t.test("motion un-parks: engaged + on-ground but moving > moveEps => loop armed", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, {}, groundMeas{ surgeVel = 2.0 })   -- scraping forward over terrain
  t.eq(L.armed, true, "moving craft treated as in-flight, not parked")
end)

t.test("airborne: engaged + not on-ground => loop armed", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, {}, groundMeas{ onGround = false })
  t.eq(L.armed, true, "airborne always active")
end)

t.test("snapshot reports parked + PARKED mode while parked", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  local snap = f:step(0.1, {}, groundMeas())
  t.eq(snap.parked, true, "parked flag set")
  t.eq(snap.mode, "PARKED", "mode reads PARKED")
end)

t.test("step always cycles the loop and returns a snapshot with flags", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  local snap = f:step(0.1, {}, meas())
  t.eq(L.cycles, 1, "cycled once")
  t.eq(snap.engaged, false); t.eq(snap.gndSafety, true)
  t.truthy(snap.altitude ~= nil, "snapshot carries telemetry")
end)
