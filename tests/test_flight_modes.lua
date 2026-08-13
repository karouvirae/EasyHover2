-- tests/test_flight_modes.lua
local t = require("tests.framework")
local Flight = require("fcs.runtime.flight")

local function fakeReg()
  local made = {}
  local function d(id, policy) return { id = id, scheme = {}, mixer = {}, caps = {}, feel = { id = id }, policy = policy } end
  return { order = {"PRECISION","MAN","CRUISE"}, default = "PRECISION",
    byId = { PRECISION = d("PRECISION", { tilt=false, surge="position" }),
             MAN = d("MAN", { tilt=true, surge="position" }),
             CRUISE = d("CRUISE", { tilt=false, surge="throttle" }) } }, made
end

t.test("flightMode command selects a mode via loop+pilot; unknown id stays", function()
  local reg = fakeReg()
  local active = { setActive = function(self, d) self.d = d end, arm = function() end }
  local pil = { setMode = function(self, p, f) self.p, self.f = p, f end,
    setPositionHold = function() end }
  local fl = Flight.new({ loop = active, pilot = pil, registry = reg })
  t.eq(fl.flightMode, "PRECISION", "boot default PRECISION")
  t.truthy(fl:handleCommand({ k = "flightMode", id = "MAN" }), "accepts MAN")
  t.eq(fl.flightMode, "MAN", "flightMode updated")
  t.eq(active.d, reg.byId.MAN, "loop switched to MAN descriptor")
  t.eq(pil.p.tilt, true, "pilot got MAN policy")
  fl:handleCommand({ k = "flightMode", id = "BOGUS" })
  t.eq(fl.flightMode, "MAN", "unknown id leaves mode unchanged")
end)
