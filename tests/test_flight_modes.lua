-- tests/test_flight_modes.lua
local t = require("tests.framework")
local Flight = require("fcs.runtime.flight")

local function fakeReg()
  local made = {}
  local function d(id, policy) return { id = id, scheme = {}, mixer = {}, caps = {}, feel = { id = id }, policy = policy } end
  return { order = {"PRECISION","MAN","CRUISE","CPL","DCPL"}, default = "PRECISION",
    byId = { PRECISION = d("PRECISION", { tilt=false, surge="position" }),
             MAN = d("MAN", { tilt=true, surge="position" }),
             CRUISE = d("CRUISE", { tilt=false, surge="throttle" }),
             CPL = d("CPL", { tilt=true, surge="coupled" }),
             DCPL = d("DCPL", { tilt=true, surge="coupled" }) } }, made
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

t.test("integration: flightMode CPL then DCPL follow in snapshot(); UNKNOWN id ignored", function()
  local reg = fakeReg()
  local active = { setActive = function(self, d) self.d = d end, arm = function() end,
    getMode = function() return "NORMAL" end }
  local pil = { setMode = function(self, p, f) self.p, self.f = p, f end,
    setPositionHold = function() end }
  local fl = Flight.new({ loop = active, pilot = pil, registry = reg })
  t.eq(fl:snapshot(nil, {}).flightMode, "PRECISION", "boot snapshot starts PRECISION")

  t.truthy(fl:handleCommand({ k = "flightMode", id = "CPL" }), "accepts CPL")
  t.eq(fl:snapshot(nil, {}).flightMode, "CPL", "snapshot() follows to CPL")
  t.eq(active.d, reg.byId.CPL, "loop switched to CPL descriptor")
  t.eq(pil.p.tilt, true, "pilot got CPL policy (tilt)")
  t.eq(pil.p.surge, "coupled", "pilot got CPL policy (coupled surge)")

  t.truthy(fl:handleCommand({ k = "flightMode", id = "DCPL" }), "accepts DCPL")
  t.eq(fl:snapshot(nil, {}).flightMode, "DCPL", "snapshot() follows to DCPL")
  t.eq(active.d, reg.byId.DCPL, "loop switched to DCPL descriptor")
  t.eq(pil.p.tilt, true, "pilot got DCPL policy (tilt)")

  local ok = fl:handleCommand({ k = "flightMode", id = "UNKNOWN" })
  t.truthy(ok, "unknown id command still handled (no crash/false)")
  t.eq(fl:snapshot(nil, {}).flightMode, "DCPL", "unknown id leaves flightMode/snapshot at DCPL (stays put)")
  t.eq(active.d, reg.byId.DCPL, "loop stays on DCPL descriptor after unknown id")
end)

t.test("flightMode switch re-syncs trimDir to the newly-active mode's own feel", function()
  local function dWithTrim(id, policy, trimDir)
    return { id = id, scheme = {}, mixer = {}, caps = {}, feel = { id = id, trimDir = trimDir }, policy = policy }
  end
  local reg = { order = {"PRECISION","CPL","DCPL"}, default = "PRECISION",
    byId = { PRECISION = { id = "PRECISION", scheme = {}, mixer = {}, caps = {}, feel = { id = "PRECISION" },
                policy = { tilt=false, surge="position" } },
             CPL = dWithTrim("CPL", { tilt=true, surge="coupled" }, 1),
             DCPL = dWithTrim("DCPL", { tilt=true, surge="coupled" }, -1) } }
  local active = { setActive = function(self, d) self.d = d end, arm = function() end,
    getMode = function() return "NORMAL" end }
  local pil = { setMode = function(self, p, f) self.p, self.f = p, f end,
    setPositionHold = function() end }
  local fl = Flight.new({ loop = active, pilot = pil, registry = reg })

  fl:handleCommand({ k = "flightMode", id = "CPL" })
  t.eq(fl:snapshot(nil, {}).trimDir, 1, "trimDir follows CPL feel.trimDir")

  fl:handleCommand({ k = "flightMode", id = "DCPL" })
  t.eq(fl:snapshot(nil, {}).trimDir, -1, "trimDir follows DCPL feel.trimDir")

  fl:handleCommand({ k = "flightMode", id = "PRECISION" })
  t.eq(fl:snapshot(nil, {}).trimDir, -1, "mode with no feel.trimDir leaves prior trimDir unchanged")
end)

t.test("flightTrim command sets pilot trim direction and telemetry echoes it", function()
  local reg = fakeReg()
  local active = { setActive = function(self, d) self.d = d end, arm = function() end,
    getMode = function() return "NORMAL" end }
  local trimSeen
  local pil = { setMode = function(self, p, f) self.p, self.f = p, f end,
    setPositionHold = function() end,
    setTrimDir = function(self, d) trimSeen = d end }
  local fl = Flight.new({ loop = active, pilot = pil, registry = reg })
  fl:handleCommand({ k = "flightTrim", dir = 1 })
  t.eq(trimSeen, 1, "pilot trim dir updated")
  t.eq(fl:snapshot(nil, {}).trimDir, 1, "telemetry echoes trimDir")
end)
