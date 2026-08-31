local t = require("tests.framework")
local C = require("fcs.io.cfgspec")

t.test("defaults + merge are additive per kind", function()
  local d = C.defaults("devbind")
  t.truthy(d.thrusters and d.sensors, "devbind shape")
  local m = C.merge("devbind", { thrusters = { FL = "thruster_3" } })
  t.eq(m.thrusters.FL, "thruster_3", "saved wins")
  t.eq(m.thrusters.FR, false, "default fills the rest")
end)

t.test("validate accepts good, rejects wrong shape", function()
  t.eq((C.validate("tuning", C.defaults("tuning"))), true)
  local ok, err = C.validate("devbind", { nope = 1 })
  t.eq(ok, false)
  t.truthy(err)
end)

t.test("load merges saved over defaults via injected reader", function()
  local body = textutils.serialise({ bindings = nil, thrusters = { MAIN = "thruster_9" } })
  local m = C.load("devbind", function() return body end)
  t.eq(m.thrusters.MAIN, "thruster_9")
end)

t.test("cfgspec fuelcal: default + file + validate", function()
  t.eq(C.FILES.fuelcal, "eh2_fuelcal.tbl", "filename")
  t.eq(C.defaults("fuelcal").fuel, "Biodiesel", "default fuel")
  -- absent file -> merged default
  local cfg = C.load("fuelcal", function() return nil end)
  t.eq(cfg.fuel, "Biodiesel", "absent -> default")
  -- saved file round-trips
  local stored
  C.save("fuelcal", { fuel = "Ethanol" }, function(_, body) stored = body end)
  local back = C.load("fuelcal", function() return stored end)
  t.eq(back.fuel, "Ethanol", "round-trip")
  t.eq((C.validate("fuelcal", { fuel = "Diesel" })), true, "valid")
  t.eq((C.validate("fuelcal", {})), false, "missing fuel invalid")
end)

t.test("legacy hw_config splits and reassembles losslessly (no calibration lost)", function()
  local hw = require("fcs.io.hwconfig").merge({
    thrusters = { FL = "thruster_1" }, sensors = { gimbal = "gimbal_0" },
    fuelRelay = "relay_0", bindings = { signHeading = -1, heightOffset = -94.5, signPitch = -1 },
  }, require("fcs.io.hwconfig").defaults())
  local split = C.splitLegacy(hw)
  t.eq(split.devbind.thrusters.FL, "thruster_1"); t.eq(split.senscal.signHeading, -1)
  local hw2 = C.assembleHw(split.devbind, split.senscal)
  t.eq(hw2.thrusters.FL, "thruster_1"); t.eq(hw2.sensors.gimbal, "gimbal_0")
  t.eq(hw2.fuelRelay, "relay_0"); t.eq(hw2.bindings.heightOffset, -94.5); t.eq(hw2.bindings.signHeading, -1)
end)

t.test("tryAssemble uses split files when present", function()
  local files = {
    ["eh2_devbind.tbl"] = textutils.serialise({ thrusters = { FL = "t_fl" }, sensors = { altimeter = "alt" } }),
    ["eh2_senscal.tbl"] = textutils.serialise({ signPitch = -1, signHeading = -1 }),
  }
  local hw, err = C.tryAssemble(function(name) return files[name] end)
  t.eq(err, nil)
  t.eq(hw.thrusters.FL, "t_fl")
  t.eq(hw.bindings.signHeading, -1)
end)

t.test("tryAssemble returns nil,nil when neither split exists", function()
  local hw, err = C.tryAssemble(function() return nil end)
  t.eq(hw, nil); t.eq(err, nil)
end)

-- F3: a split is only usable when BOTH files exist. If only one is present, load() returns
-- IDENTITY defaults for the missing kind (signHeading=1, gimbalRollIdx=2, ...); assembling then
-- would fly a real craft (signHeading=-1) with an identity sign map -- the Flight #9 negative
-- spring. tryAssemble must instead return nil so the caller falls through to the fused config.
t.test("tryAssemble returns nil,nil when only devbind exists (falls through to fused)", function()
  local files = { ["eh2_devbind.tbl"] = textutils.serialise({ thrusters = { FL = "t_fl" }, sensors = { altimeter = "alt" } }) }
  local hw, err = C.tryAssemble(function(name) return files[name] end)
  t.eq(hw, nil); t.eq(err, nil)
end)

t.test("tryAssemble returns nil,nil when only senscal exists (falls through to fused)", function()
  local files = { ["eh2_senscal.tbl"] = textutils.serialise({ signPitch = -1, signHeading = -1 }) }
  local hw, err = C.tryAssemble(function(name) return files[name] end)
  t.eq(hw, nil); t.eq(err, nil)
end)

t.test("tryAssemble still returns nil,err on a corrupt split (no silent fused-over-corrupt)", function()
  local files = { ["eh2_devbind.tbl"] = "not a table",
                  ["eh2_senscal.tbl"] = textutils.serialise({ signPitch = 1, signHeading = 1 }) }
  local hw, err = C.tryAssemble(function(name) return files[name] end)
  t.eq(hw, nil); t.truthy(err)
end)
