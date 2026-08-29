-- tests/test_region_fcs.lua
local t = require("tests.framework")
local FcsRegion = require("ui.basalt.regions.fcs")
local Region = require("ui.basalt.region")
local BasaltApp = require("ui.basalt.app")

-- Stub runtime: rx.latest controllable; links.tel records sends; sender:send returns the cmd.
local function stubRuntime(latest)
  local sent = {}
  return {
    sent = sent,
    rx = { latest = function() return latest end },
    sender = { send = function(_, cmd) return cmd end },
    links = { tel = { send = function(_, frame) sent[#sent + 1] = frame end } },
  }, sent
end

t.test("_onFcs toggles engage (gated by gndSafety) and ground safety, sending commands", function()
  -- disengaged + safe: engage is blocked (gndSafety) -> no command
  local rt = stubRuntime({ engaged = false, gndSafety = true })
  FcsRegion._onFcs(rt, "fcs", 1)
  t.eq(#rt.sent, 0, "engage blocked while GND safety on")

  -- disengaged + not safe: engage sends
  rt = stubRuntime({ engaged = false, gndSafety = false })
  local eff = FcsRegion._onFcs(rt, "fcs", 1)
  t.eq(#rt.sent, 1); t.eq(rt.sent[1].k, "engage")

  -- engaged: FCS toggles to disengage
  rt = stubRuntime({ engaged = true, gndSafety = false })
  FcsRegion._onFcs(rt, "fcs", 1)
  t.eq(rt.sent[1].k, "disengage")

  -- GND toggles ground safety (on = not current)
  rt = stubRuntime({ engaged = false, gndSafety = false })
  FcsRegion._onFcs(rt, "gnd", 1)
  t.eq(rt.sent[1].k, "gndSafety"); t.eq(rt.sent[1].on, true)
end)

t.test("fcs region screens build + render on a real Region without error", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local rt = stubRuntime({ engaged = false, gndSafety = true, mode = "HOVER", altitude = 12.3, loopHz = 18 })
  local r = Region.new(basalt, parent, {
    x = 1, y = 13, width = 14, height = 12, root = "fcs_main",
    screens = {
      fcs_main   = function(b, f, rg) return FcsRegion.main(b, f, rg, rt) end,
      fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end,
    },
  })
  r:apply({ engaged = false, gndSafety = true })          -- fcs_main
  r:push("fcs_params"); r:apply({ mode = "HOVER", altitude = 12.3, loopHz = 18 })  -- fcs_params
  r:pop(); r:apply({ engaged = true, gndSafety = false })  -- back to main, engaged
  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("fcs_params apply shows flightMode/TAS/loopHz, not loop-state MODE", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local rt = stubRuntime({ engaged = true, gndSafety = false })
  local r = Region.new(basalt, parent, {
    x = 1, y = 1, width = 36, height = 20, root = "fcs_params",
    screens = {
      fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end,
    },
  })
  r:apply({
    mode = "PARKED", flightMode = "LDG", tas = 8.2, loopHz = 10,
    altitude = 12, vSpeed = 0.5, heading = 90, linkUp = true, gndSafety = false,
  })
  local L = r.built.fcs_params.handle.elements.labels
  local function txt(name) return L[name].lbl:getText() end
  t.truthy(txt("MODE"):find("LDG/%-%-%-%-", 1, false), "MODE is flight mode, not PARKED")
  t.truthy(not txt("MODE"):find("PARKED", 1, true), "loop state must not appear")
  t.truthy(txt("TRUSPD"):find("8ms", 1, true), "TRU SPD from tas")
  t.truthy(txt("FCSLOOP"):find("100ms", 1, true), "FCS LOOP from loopHz")
  t.truthy(txt("PROXWRN"):find("OFF", 1, true))
  t.truthy(txt("APLOOP"):find("%-%-ms", 1, false))
  t.truthy(txt("APMODE"):find("IDLE", 1, true))
end)
