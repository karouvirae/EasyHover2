-- tests/test_flight_master.lua
local t = require("tests.framework")
local Flight = require("fcs.runtime.flight")

local function fakePilot() return { calls = {},
  setMode = function() end, setPositionHold = function() end, reset = function() end,
  setTrimDir = function() end,
  setMaster = function(self, v) self.calls[#self.calls+1] = v end } end
local function fakeLoop() return { trims = {}, sp = nil,
  setActive = function() end, arm = function() end, setpoints = function() end,
  clearDamped = function() end, getMode = function() return "NORMAL" end,
  cycle = function() return { mode = "NORMAL", m = {} } end,
  setTrim = function(self, d, g) self.trims[#self.trims+1] = { d, g } end } end
local function reg()
  return { default = "LDG", order = { "LDG" },
    byId = { LDG = { id = "LDG", policy = {}, feel = { trimGain = 0.35, trimDir = -1 }, caps = {} } } }
end

t.test("flight: default master CPL; masterMode command sets driftArrest via pilot", function()
  local pilot = fakePilot()
  local f = Flight.new({ loop = fakeLoop(), pilot = pilot, registry = reg() })
  t.eq(f.masterMode, "CPL", "boot master CPL")
  t.truthy(f:handleCommand({ k = "masterMode", id = "DCPL" }), "command handled")
  t.eq(f.masterMode, "DCPL", "master switched to DCPL")
  t.eq(pilot.calls[#pilot.calls], false, "pilot told driftArrest=false for DCPL")
  f:handleCommand({ k = "masterMode", id = "CPL" })
  t.eq(pilot.calls[#pilot.calls], true, "pilot told driftArrest=true for CPL")
  f:handleCommand({ k = "masterMode", id = "BOGUS" })
  t.eq(f.masterMode, "CPL", "unknown master id ignored")
end)

t.test("flight: snapshot reports masterMode", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = fakePilot(), registry = reg() })
  local snap = f:snapshot(nil, {})
  t.eq(snap.masterMode, "CPL", "masterMode on snapshot")
end)
