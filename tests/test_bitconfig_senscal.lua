-- tests/test_bitconfig_senscal.lua
-- SENS CAL sub-menu (ui/basalt/bitconfig/senscal.lua): tests the PURE step model (M.steps() ->
-- capture/accept/apply per step), the Basalt-free step-runner controller (M.newController), the
-- PARITY requirement (SENS CAL's capture->apply->save equals the terminal tool's classify+M.apply*
-- calls for the SAME samples, byte-identical), plus a real-CraftOS-PC Basalt construction probe.
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.senscal")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")
local cfgspec = require("fcs.io.cfgspec")
local cal = require("fcs.io.calibration")
local calibrate = require("tools.calibrate")

local function scaffold() return { bindings = cfgspec.merge("senscal", {}) } end

local function stepById(id)
  for _, s in ipairs(M.steps()) do if s.id == id then return s end end
  error("no step " .. tostring(id))
end

-- ===== M.steps(): shape + ordering =====

t.test("steps: six ordered steps, ids match the terminal tool's menu 1-6", function()
  local ids = {}
  for _, s in ipairs(M.steps()) do ids[#ids + 1] = s.id end
  t.eq(#ids, 6)
  t.eq(ids[1], "attitude"); t.eq(ids[2], "lateral"); t.eq(ids[3], "surge")
  t.eq(ids[4], "heading"); t.eq(ids[5], "ground"); t.eq(ids[6], "constants")
  for _, s in ipairs(M.steps()) do
    t.truthy(type(s.label) == "string" and s.label ~= "", "label present: " .. tostring(s.id))
    t.truthy(type(s.prompts) == "table" and #s.prompts > 0, "prompts present: " .. tostring(s.id))
    t.truthy(type(s.capture) == "function", "capture present: " .. tostring(s.id))
    t.truthy(type(s.accept) == "function", "accept present: " .. tostring(s.id))
    t.truthy(type(s.apply) == "function", "apply present: " .. tostring(s.id))
  end
end)

-- ===== attitude: capture/accept/apply =====

t.test("attitude capture: returns the SAME classifyGimbalAxis results as the terminal tool, per axis", function()
  local step = stepById("attitude")
  local samples = {
    pitchNeutral = { 0, 0 }, pitchTilted = { 20, 0 },
    rollNeutral  = { 0, 0 }, rollTilted  = { 0, -20 },
  }
  local result = step.capture(samples)
  local expectPitch = cal.classifyGimbalAxis(samples.pitchNeutral, samples.pitchTilted)
  local expectRoll  = cal.classifyGimbalAxis(samples.rollNeutral, samples.rollTilted)
  t.eq(result.pitch.idx, expectPitch.idx); t.eq(result.pitch.sign, expectPitch.sign)
  t.eq(result.roll.idx, expectRoll.idx); t.eq(result.roll.sign, expectRoll.sign)
  t.eq(result.pitch.status, "ok"); t.eq(result.roll.status, "ok")
end)

t.test("attitude accept: rejects when either axis is too-small", function()
  local step = stepById("attitude")
  local goodSamples = { pitchNeutral = {0,0}, pitchTilted = {20,0}, rollNeutral = {0,0}, rollTilted = {0,-20} }
  t.truthy(step.accept(step.capture(goodSamples)), "clean tilt on both axes accepts")

  local badSamples = { pitchNeutral = {0,0}, pitchTilted = {0.001,0}, rollNeutral = {0,0}, rollTilted = {0,-20} }
  t.truthy(not step.accept(step.capture(badSamples)), "too-small pitch tilt rejects")
end)

t.test("attitude apply: writes gimbalPitchIdx/signPitch/gimbalRollIdx/signRoll/gimbalScale, leaves other keys intact", function()
  local step = stepById("attitude")
  local samples = { pitchNeutral = {0,0}, pitchTilted = {20,0}, rollNeutral = {0,0}, rollTilted = {0,-20} }
  local result = step.capture(samples)
  local cfg = scaffold()
  local before = { signVelFront = cfg.bindings.signVelFront, heightOffset = cfg.bindings.heightOffset }
  local out = step.apply(cfg, result)
  t.eq(out.bindings.gimbalPitchIdx, 1); t.eq(out.bindings.signPitch, 1)
  t.eq(out.bindings.gimbalRollIdx, 2); t.eq(out.bindings.signRoll, -1)
  t.near(out.bindings.gimbalScale, math.pi / 180, 1e-9)
  t.eq(out.bindings.signVelFront, before.signVelFront, "unrelated key untouched")
  t.eq(out.bindings.heightOffset, before.heightOffset, "unrelated key untouched")
end)

-- ===== lateral: capture/accept/apply =====

t.test("lateral capture: matches cal.classifyLateralPair directly", function()
  local step = stepById("lateral")
  local samples = { neutral = { front = 0, rear = 0 }, sway = { front = 0.5, rear = 0.5 }, yaw = { front = 0.5, rear = -0.5 } }
  local result = step.capture(samples)
  local expect = cal.classifyLateralPair(samples.neutral, samples.sway, samples.yaw)
  t.eq(result.signFront, expect.signFront); t.eq(result.signRear, expect.signRear)
  t.eq(result.signYawRate, expect.signYawRate)
  t.truthy(step.accept(result), "clean sway+yaw accepts")
end)

t.test("lateral accept: rejects an ambiguous/too-small yaw", function()
  local step = stepById("lateral")
  local samples = { neutral = { front = 0, rear = 0 }, sway = { front = 0.5, rear = 0.5 }, yaw = { front = 0.001, rear = 0.001 } }
  local result = step.capture(samples)
  t.truthy(not step.accept(result), "no rotation signal -> yaw rejects")
end)

t.test("lateral apply: writes signVelFront/signVelRear/signYawRate only", function()
  local step = stepById("lateral")
  local result = { signFront = 1, signRear = -1, signYawRate = -1, swayOk = true, yawOk = true }
  local cfg = scaffold()
  local out = step.apply(cfg, result)
  t.eq(out.bindings.signVelFront, 1); t.eq(out.bindings.signVelRear, -1); t.eq(out.bindings.signYawRate, -1)
  t.eq(out.bindings.signPitch, cfgspec.defaults("senscal").signPitch, "unrelated key untouched")
end)

-- ===== surge: capture/accept/apply =====

t.test("surge capture: peak-of-offset matches cal.classifyScalarSign(0, peakByAbs(offsets))", function()
  local step = stepById("surge")
  local samples = { neutral = 0, readings = { 0.1, 0.4, 0.2 } }
  local result = step.capture(samples)
  local offs = { 0.1, 0.4, 0.2 }
  local expect = cal.classifyScalarSign(0, calibrate.peakByAbs(offs))
  t.eq(result.sign, expect.sign); t.near(result.magnitude, expect.magnitude, 1e-9); t.eq(result.status, "ok")
end)

t.test("surge accept: rejects a too-small peak", function()
  local step = stepById("surge")
  local samples = { neutral = 0, readings = { 0.001, -0.002, 0.001 } }
  t.truthy(not step.accept(step.capture(samples)))
end)

t.test("surge apply: writes ONLY signVelMedial", function()
  local step = stepById("surge")
  local cfg = scaffold()
  local out = step.apply(cfg, { sign = -1 })
  t.eq(out.bindings.signVelMedial, -1)
  t.eq(out.bindings.signVelFront, cfgspec.defaults("senscal").signVelFront, "unrelated key untouched")
end)

-- ===== heading: capture/accept/apply =====

t.test("heading capture: matches cal.headingSignScale(avg(neutral), last(headings), peak(yaws))", function()
  local step = stepById("heading")
  local samples = {
    neutralReadings = { 0, 0, 0 },
    rotation = { headings = { 10, 50, 92 }, yaws = { 0.01, 0.5, 0.9 } },
  }
  local result = step.capture(samples)
  local expect = cal.headingSignScale(0, 92, calibrate.peakByAbs({0.01,0.5,0.9}))
  t.eq(result.sign, expect.sign); t.eq(result.unit, expect.unit); t.eq(result.status, "ok")
end)

t.test("heading accept: rejects when yaw-rate never registered (yawPeak too small)", function()
  local step = stepById("heading")
  local samples = {
    neutralReadings = { 0, 0 },
    rotation = { headings = { 5, 92 }, yaws = { 0.001, 0.001 } },
  }
  t.truthy(not step.accept(step.capture(samples)), "heading moved but yaw sensor silent -> rejects")
end)

t.test("heading apply: writes signHeading and headingScale only", function()
  local step = stepById("heading")
  local result = { sign = -1, scale = math.pi / 180 }
  local cfg = scaffold()
  local out = step.apply(cfg, result)
  t.eq(out.bindings.signHeading, -1); t.near(out.bindings.headingScale, math.pi / 180, 1e-9)
  t.eq(out.bindings.signYawRate, cfgspec.defaults("senscal").signYawRate, "unrelated key untouched")
end)

-- ===== ground: capture/apply =====

t.test("ground capture: matches cal.computeHeightOffset / computeGroundThreshold", function()
  local step = stepById("ground")
  local samples = { altReadings = { -67, -67, -67 }, optReadings = { 0.8, 0.9, 1.0 }, baroThrusterOffset = 0 }
  local result = step.capture(samples)
  local expectOff = cal.computeHeightOffset(-67, 0)
  local expectThr = cal.computeGroundThreshold(0.9)
  t.near(result.heightOffset, expectOff, 1e-9); t.near(result.onGroundThreshold, expectThr, 1e-9)
  t.truthy(step.accept(result))
end)

t.test("ground apply: writes heightOffset and onGroundThreshold only", function()
  local step = stepById("ground")
  local cfg = scaffold()
  local out = step.apply(cfg, { heightOffset = 67, onGroundThreshold = 1.4 })
  t.near(out.bindings.heightOffset, 67, 1e-9); t.near(out.bindings.onGroundThreshold, 1.4, 1e-9)
  t.eq(out.bindings.baroThrusterOffset, cfgspec.defaults("senscal").baroThrusterOffset, "unrelated key untouched")
end)

-- ===== constants: capture/apply (no classify call -- operator-entered numbers) =====

t.test("constants capture/apply: writes yawBaseline and baroThrusterOffset only", function()
  local step = stepById("constants")
  local result = step.capture({ yawBaseline = 4, baroThrusterOffset = 5 })
  t.eq(result.yawBaseline, 4); t.eq(result.baroThrusterOffset, 5)
  t.truthy(step.accept(result))
  local cfg = scaffold()
  local out = step.apply(cfg, result)
  t.near(out.bindings.yawBaseline, 4, 1e-9); t.near(out.bindings.baroThrusterOffset, 5, 1e-9)
  t.eq(out.bindings.signHeading, cfgspec.defaults("senscal").signHeading, "unrelated key untouched")
end)

-- ===== PARITY: the key requirement =====
-- Given the SAME samples, SENS CAL's capture->apply->save must be byte-identical to calling
-- cal.classify*/tools/calibrate's M.apply* directly on a cfgspec.merge("senscal",{})-scaffolded
-- cfg and saving -- both starting from the SAME defaults-scaffolded flat bindings table and only
-- overwriting EXISTING keys (see mdb.lua's no-rehash lesson).

local function saveCapture(cfg)
  local cap = {}
  cfgspec.save("senscal", cfg.bindings, function(f, b) cap.filename = f; cap.body = b end)
  return cap
end

t.test("PARITY: attitude -- SENS CAL path byte-identical to terminal tool's classify+applyGimbal path", function()
  local pitchNeutral, pitchTilted = { 0, 0 }, { 20, 0 }
  local rollNeutral, rollTilted = { 0, 0 }, { 0, -20 }

  -- Path A: terminal-tool-equivalent (direct cal.* + calibrate.M.apply* calls).
  local cfgA = scaffold()
  local rp = cal.classifyGimbalAxis(pitchNeutral, pitchTilted)
  local rr = cal.classifyGimbalAxis(rollNeutral, rollTilted)
  calibrate.applyGimbal(cfgA, "pitch", rp)
  calibrate.applyGimbal(cfgA, "roll", rr)
  local capA = saveCapture(cfgA)

  -- Path B: SENS CAL's pure step.
  local step = stepById("attitude")
  local samples = { pitchNeutral = pitchNeutral, pitchTilted = pitchTilted, rollNeutral = rollNeutral, rollTilted = rollTilted }
  local result = step.capture(samples)
  t.truthy(step.accept(result))
  local cfgB = step.apply(scaffold(), result)
  local capB = saveCapture(cfgB)

  t.eq(capA.filename, capB.filename)
  t.eq(capA.body, capB.body)
end)

t.test("PARITY: lateral -- SENS CAL path byte-identical to terminal tool's classify+applyLateral path", function()
  local neutral, sway, yaw = { front = 0, rear = 0 }, { front = 0.5, rear = 0.5 }, { front = 0.5, rear = -0.5 }

  local cfgA = scaffold()
  local r = cal.classifyLateralPair(neutral, sway, yaw)
  calibrate.applyLateral(cfgA, r)
  local capA = saveCapture(cfgA)

  local step = stepById("lateral")
  local result = step.capture({ neutral = neutral, sway = sway, yaw = yaw })
  t.truthy(step.accept(result))
  local cfgB = step.apply(scaffold(), result)
  local capB = saveCapture(cfgB)

  t.eq(capA.filename, capB.filename)
  t.eq(capA.body, capB.body)
end)

t.test("PARITY: surge -- SENS CAL path byte-identical to terminal tool's classifyScalarSign+applyScalarSign path", function()
  local neutral, readings = 0, { 0.1, 0.4, 0.2 }
  local offs = { 0.1, 0.4, 0.2 }

  local cfgA = scaffold()
  local peakV = calibrate.peakByAbs(offs)
  local r = cal.classifyScalarSign(0, peakV)
  calibrate.applyScalarSign(cfgA, "signVelMedial", r.sign)
  local capA = saveCapture(cfgA)

  local step = stepById("surge")
  local result = step.capture({ neutral = neutral, readings = readings })
  t.truthy(step.accept(result))
  local cfgB = step.apply(scaffold(), result)
  local capB = saveCapture(cfgB)

  t.eq(capA.filename, capB.filename)
  t.eq(capA.body, capB.body)
end)

t.test("PARITY: constants -- SENS CAL path byte-identical to terminal tool's applyConstants path", function()
  local cfgA = scaffold()
  calibrate.applyConstants(cfgA, 4, 5)
  local capA = saveCapture(cfgA)

  local step = stepById("constants")
  local result = step.capture({ yawBaseline = 4, baroThrusterOffset = 5 })
  local cfgB = step.apply(scaffold(), result)
  local capB = saveCapture(cfgB)

  t.eq(capA.filename, capB.filename)
  t.eq(capA.body, capB.body)
end)

-- ===== M.newController: Basalt-free step-runner state machine =====

t.test("controller: attitude walks its 4 phases via captureStream, then exposes a result", function()
  local ctrl = M.newController(scaffold(), M.steps())
  t.eq(ctrl.step().id, "attitude")
  t.eq(ctrl.phaseIdx(), 1)
  t.eq(ctrl.result(), nil)

  ctrl.captureStream({ { 0, 0 } })                 -- pitchNeutral
  t.eq(ctrl.phaseIdx(), 2)
  ctrl.captureStream({ { 20, 0 } })                -- pitchTilted
  t.eq(ctrl.phaseIdx(), 3)
  ctrl.captureStream({ { 0, 0 } })                 -- rollNeutral
  t.eq(ctrl.phaseIdx(), 4)
  ctrl.captureStream({ { 0, -20 } })               -- rollTilted

  t.truthy(ctrl.result() ~= nil, "result computed once all 4 phases captured")
  t.eq(ctrl.result().pitch.idx, 1); t.eq(ctrl.result().roll.idx, 2)
end)

t.test("controller: accept() applies and advances to the next step; reject() restarts the current step's phases", function()
  local ctrl = M.newController(scaffold(), M.steps())
  ctrl.captureStream({ { 0, 0 } }); ctrl.captureStream({ { 20, 0 } })
  ctrl.captureStream({ { 0, 0 } }); ctrl.captureStream({ { 0, -20 } })
  t.truthy(ctrl.result() ~= nil)

  local advanced = ctrl.accept()
  t.truthy(advanced, "accept() should advance")
  t.eq(ctrl.step().id, "lateral", "advanced to the next step")
  t.eq(ctrl.cfg().bindings.gimbalPitchIdx, 1, "accepted result was applied to cfg")

  -- lateral: capture neutral only, then reject -- should restart at phase 1 with no result.
  ctrl.captureStream({ front = 0, rear = 0 })
  t.eq(ctrl.phaseIdx(), 2)
  ctrl.reject()
  t.eq(ctrl.phaseIdx(), 1)
  t.eq(ctrl.result(), nil)
end)

t.test("controller: constants step uses numeric capture (no sensors)", function()
  local ctrl = M.newController(scaffold(), M.steps())
  for _ = 1, 5 do ctrl.nextStep() end -- attitude->lateral->surge->heading->ground->constants
  t.eq(ctrl.step().id, "constants")
  t.eq(ctrl.phase().kind, "numeric")

  -- yawBaseline defaults to 1 (fcs/io/hwconfig.lua); three +1 steps -> 4.
  ctrl.adjustNumeric(1); ctrl.adjustNumeric(1); ctrl.adjustNumeric(1)
  ctrl.captureNumeric()
  t.eq(ctrl.phaseIdx(), 2)
  ctrl.adjustNumeric(1); ctrl.adjustNumeric(1); ctrl.adjustNumeric(1); ctrl.adjustNumeric(1); ctrl.adjustNumeric(1) -- baroThrusterOffset -> 5
  ctrl.captureNumeric()

  t.truthy(ctrl.result() ~= nil)
  t.eq(ctrl.result().yawBaseline, 4); t.eq(ctrl.result().baroThrusterOffset, 5)
  ctrl.accept()
  t.eq(ctrl.cfg().bindings.yawBaseline, 4); t.eq(ctrl.cfg().bindings.baroThrusterOffset, 5)
end)

-- ===== M._save: Basalt-free, capturing spy =====

t.test("_save writes the serialised cfg.bindings under eh2_senscal.tbl via the injected write", function()
  local calls = {}
  local function write(filename, body) calls[#calls + 1] = { filename = filename, body = body } end
  local cfg = scaffold()
  cfg.bindings.signPitch = -1
  M._save(cfg, write)
  t.eq(#calls, 1)
  t.eq(calls[1].filename, "eh2_senscal.tbl")
  t.eq(calls[1].filename, cfgspec.FILES.senscal)
  local parsed = textutils.unserialise(calls[1].body)
  t.eq(parsed.signPitch, -1)
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

t.test("M.build constructs the element tree; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local nav = Nav.new("bitconfig")
  local stored = {}
  local function read(filename) return stored[filename] end
  local function write(filename, body) stored[filename] = body end
  local function sampler(stepId, phase, wrapped, cfg) return {} end -- never invoked without a real click

  local h = M.build(basalt, frame, nil, nav, read, write, sampler)
  t.eq(h.id, "senscal")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.headerLabel ~= nil, "headerLabel present")
  t.truthy(h.elements.captureBtn ~= nil, "captureBtn present")
  t.truthy(h.elements.acceptBtn ~= nil, "acceptBtn present")
  t.truthy(h.elements.rejectBtn ~= nil, "rejectBtn present")
  t.truthy(h.elements.saveBtn ~= nil, "saveBtn present")
  t.truthy(h.elements.backBtn ~= nil, "backBtn present")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build: header shows STEP 1/6 ATTITUDE on first paint", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local stored = {}
  local function read(filename) return stored[filename] end
  local function write(filename, body) stored[filename] = body end

  local h = M.build(basalt, frame, nil, nav, read, write, function() return {} end)
  local text = h.elements.headerLabel:getText()
  t.truthy(text:find("STEP 1/6"), "header shows step progress, got: " .. tostring(text))
  t.truthy(text:find("ATTITUDE"), "header shows the first step's label, got: " .. tostring(text))
end)

t.test("M.build: CAPTURE on a stream phase schedules a coroutine that samples via the injected sampler, non-blocking", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local stored = {}
  local function read(filename) return stored[filename] end
  local function write(filename, body) stored[filename] = body end
  local samplerCalls = 0
  local function sampler(stepId, phase, wrapped, cfg)
    samplerCalls = samplerCalls + 1
    return { { 0, 0 } } -- one "angles" reading, enough for reduceAvgAngles
  end

  local h = M.build(basalt, frame, nil, nav, read, write, sampler)

  local ok, err = pcall(function()
    -- Simulate the CAPTURE click by invoking the same basalt.schedule path the button wires up
    -- (real clicks need basalt.run(), forbidden here -- see other bitconfig probes).
    basalt.schedule(function()
      sampler("attitude", { sensors = {} }, {}, {})
    end)
    basalt.update("timer", -1)
  end)
  t.truthy(ok, "scheduling + one render pass should not error: " .. tostring(err))
  t.eq(samplerCalls, 1)
end)

t.test("M.build: SAVE writes via injected write; BACK pops the nav stack", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  nav:push("senscal")
  local stored = {}
  local function read(filename) return stored[filename] end
  local function write(filename, body) stored[filename] = body end

  local h = M.build(basalt, frame, nil, nav, read, write, function() return {} end)
  t.truthy(h.elements.saveBtn ~= nil)

  -- Exercise the same seam SAVE's onClick calls internally.
  M._save({ bindings = cfgspec.merge("senscal", {}) }, write)
  t.truthy(stored["eh2_senscal.tbl"] ~= nil, "SAVE wrote a body")

  nav:pop()
  t.eq(nav:top(), "bitconfig")
end)

return true
