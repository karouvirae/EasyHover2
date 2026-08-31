local t = require("tests.framework")
local C = require("tools.calibrate")

local function cfg() return { thrusters={}, sensors={}, bindings={} } end

t.test("_loadCal returns err on unparseable split and not defaults", function()
  local cfg, err = C._loadCal(function(name)
    if name == "eh2_senscal.tbl" then return "not a table" end
    return nil
  end)
  t.eq(cfg, nil)
  t.eq(err, "unparseable")
end)

t.test("average of a list", function() t.near(C.average({2,4,6}), 4, 1e-9) end)
t.test("average of empty is 0", function() t.near(C.average({}), 0, 1e-9) end)
t.test("peakByAbs picks largest magnitude, keeping sign", function()
  t.near(C.peakByAbs({0.1, -0.9, 0.3}), -0.9, 1e-9)
end)
t.test("argmaxAbs returns the index of largest magnitude", function()
  t.eq(C.argmaxAbs({0.1, -0.9, 0.3}), 2)
end)
t.test("applyGimbal writes pitch idx/sign and shared scale", function()
  local c = C.applyGimbal(cfg(), "pitch", {idx=2, sign=-1, scale=math.pi/180})
  t.eq(c.bindings.gimbalPitchIdx, 2); t.eq(c.bindings.signPitch, -1)
  t.near(c.bindings.gimbalScale, math.pi/180, 1e-9)
end)
t.test("applyGimbal writes roll idx/sign", function()
  local c = C.applyGimbal(cfg(), "roll", {idx=1, sign=1, scale=1})
  t.eq(c.bindings.gimbalRollIdx, 1); t.eq(c.bindings.signRoll, 1)
end)
t.test("applyLateral writes both velocity signs and yaw-rate sign", function()
  local c = C.applyLateral(cfg(), {signFront=1, signRear=-1, signYawRate=-1})
  t.eq(c.bindings.signVelFront, 1); t.eq(c.bindings.signVelRear, -1); t.eq(c.bindings.signYawRate, -1)
end)
t.test("applyScalarSign writes an arbitrary sign binding", function()
  t.eq(C.applyScalarSign(cfg(), "signVelMedial", -1).bindings.signVelMedial, -1)
end)

-- L3: applyHeading calibrates signHeading CONSISTENT with the signYawRate present at the time
-- (headingSignScale cross-checks them). Re-running LATERAL rewrites signYawRate; if it flips and
-- heading was already set, signHeading must flip too or the heading loop becomes a negative spring
-- (Flight #9). Untouched when yawRate is unchanged or heading was never calibrated.
t.test("applyLateral flips signHeading when a re-run inverts signYawRate (keeps the pair consistent)", function()
  local c = { bindings = { signHeading = -1, compassSign = -1, signYawRate = 1 } }
  C.applyLateral(c, { signFront = 1, signRear = -1, signYawRate = -1 })   -- yawRate flips +1 -> -1
  t.eq(c.bindings.signYawRate, -1, "new yawRate sign written")
  t.eq(c.bindings.signHeading, 1, "signHeading flipped to stay consistent with the flipped yawRate")
  t.eq(c.bindings.compassSign, 1, "compassSign follows signHeading")
end)

t.test("applyLateral leaves signHeading when signYawRate is unchanged", function()
  local c = { bindings = { signHeading = -1, compassSign = -1, signYawRate = 1 } }
  C.applyLateral(c, { signFront = 1, signRear = -1, signYawRate = 1 })    -- same yawRate sign
  t.eq(c.bindings.signHeading, -1, "heading untouched when the pair already agrees")
  t.eq(c.bindings.compassSign, -1)
end)

t.test("applyLateral does not invent signHeading when heading was never calibrated", function()
  local c = { bindings = { signYawRate = 1 } }                            -- no signHeading yet
  C.applyLateral(c, { signFront = 1, signRear = -1, signYawRate = -1 })
  t.eq(c.bindings.signHeading, nil, "no heading to flip -> left unset")
end)
t.test("applyHeading writes sign and scale", function()
  local c = C.applyHeading(cfg(), {sign=-1, scale=math.pi/180})
  t.eq(c.bindings.signHeading, -1); t.near(c.bindings.headingScale, math.pi/180, 1e-9)
end)
t.test("applyHeading writes compassSign equal to signHeading", function()
  local c = C.applyHeading(cfg(), {sign=-1, scale=math.pi/180})
  t.eq(c.bindings.compassSign, -1)
  t.eq(c.bindings.compassSign, c.bindings.signHeading)
end)
t.test("applyGround writes height offset and threshold", function()
  local c = C.applyGround(cfg(), -67, 1.0)
  t.near(c.bindings.heightOffset, -67, 1e-9); t.near(c.bindings.onGroundThreshold, 1.0, 1e-9)
end)
t.test("applyConstants writes baseline and baro offset", function()
  local c = C.applyConstants(cfg(), 4, 5)
  t.near(c.bindings.yawBaseline, 4, 1e-9); t.near(c.bindings.baroThrusterOffset, 5, 1e-9)
end)

t.test("calibrate persists to eh2_senscal.tbl and read-through migrates legacy", function()
  local C = require("tools.calibrate")
  local cfg = C._loadCal(function(p) return p == "/eh2_hw_config.tbl"
    and textutils.serialise(require("fcs.io.hwconfig").defaults()) or nil end)  -- only legacy present
  t.truthy(cfg.signPitch ~= nil, "legacy bindings migrated into senscal cfg")
end)
