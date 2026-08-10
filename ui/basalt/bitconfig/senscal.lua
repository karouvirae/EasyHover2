-- ui/basalt/bitconfig/senscal.lua
-- SENS CAL sub-menu (BIT/CONFIG hub, screen id "senscal"): the native-Basalt guided sensor
-- calibration -- a reskin of the terminal tool tools/calibrate.lua's guided flow. Writes
-- /eh2_senscal.tbl via fcs/io/cfgspec.lua and MUST produce a byte-identical file to the
-- terminal tool for the same samples (enforced by the PARITY test in
-- tests/test_bitconfig_senscal.lua).
--
-- This module REUSES, rather than reimplements:
--   * fcs/io/calibration.lua's pure cal.classifyGimbalAxis/classifyLateralPair/
--     classifyScalarSign/headingSignScale/computeHeightOffset/computeGroundThreshold -- the
--     SAME classify calls the terminal tool makes.
--   * tools/calibrate.lua's pure M.average/M.peakByAbs/M.argmaxAbs/M.apply* helpers and its
--     M.stream sleep-loop sampler.
-- Byte-identical parity depends on BOTH sides calling the SAME classify/apply functions on a
-- cfgspec.merge("senscal", ...)-scaffolded flat bindings table, mutating EXISTING keys only
-- (never inserting a new key -- see ui/basalt/bitconfig/mdb.lua's header for the full no-rehash
-- rationale: textutils.serialise output depends on table hash-layout, and cfgspec.merge always
-- rebuilds its output by iterating the FRESH cfgspec.defaults(...) call's own pairs() order, so
-- it -- and only it -- is safe to use as the starting scaffold).
--
-- ===== PURE STEP MODEL (M.steps()) =====
-- Six ordered guided steps: attitude (pitch+roll), lateral, surge, heading, ground, constants.
-- Each step descriptor is { id, label, prompts, capture(samples), accept(result), apply(cfg,
-- result) }. `capture`/`apply` are PURE: samples/result in, a classify result / a new-ish cfg
-- out -- no peripheral access, no read()/write(), no Basalt. `prompts` is the ORDERED list of
-- operator instruction strings for this step's guided phases (mirrors the terminal tool's
-- print()/read() prompts one-for-one; the Basalt runner below shows prompts[phaseIdx] and walks
-- the list one CAPTURE press at a time).
--
-- ===== BASALT RUNNER (M.build) =====
-- Below the pure model, M.build() wires a step-runner UI: a per-phase CAPTURE button that
-- samples the bound sensors (from eh2_devbind) over the phase's duration on a basalt.schedule
-- coroutine (non-blocking -- sleep() works inside a scheduled coroutine per ui/basalt/app.lua's
-- M.startScheduled header notes and release/basalt-full.lua's b_a.schedule/bca dispatch, verified
-- against source), reduces the raw stream into that phase's contribution to `samples`, and once
-- every phase for the current step is captured, computes `step.capture(samples)`, gates on
-- `step.accept(result)`, and shows ACCEPT/REJECT. ACCEPT calls `step.apply(cfg, result)` and
-- advances to the next step; REJECT discards the step's in-progress samples and restarts its
-- phases. SAVE calls `cfgspec.save("senscal", cfg.bindings, write)`. `< BACK` pops the nav stack.
-- Read/write/sampler are injected (5th/6th/7th M.build args) so tests drive this without real
-- peripherals; the "constants" step needs no sensors at all (operator-entered numbers) and uses
-- a +/- stepper instead of CAPTURE, matching tools/calibrate.lua's stepConstants prompt-for-a-
-- number flow.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/the closures it
-- returns, so `require("ui.basalt.bitconfig.senscal")` loads clean headless.

local cal       = require("fcs.io.calibration")
local calibrate = require("tools.calibrate")
local cfgspec   = require("fcs.io.cfgspec")
local shim      = require("fcs.io.shim")

local M = {}
M.id = "senscal"
M.title = "SENS CAL"

-- ===================================================================================
-- ===== PURE per-step capture/accept/apply, one-for-one with tools/calibrate.lua's =====
-- ===== stepAttitude/stepLateral/stepSurge/stepHeading/stepGround/stepConstants.   =====
-- ===================================================================================

-- ---- attitude: pitch AND roll, each via cal.classifyGimbalAxis(neutral, tilted) ----
local function attitudeCapture(samples)
  local pitch = cal.classifyGimbalAxis(samples.pitchNeutral, samples.pitchTilted)
  local roll  = cal.classifyGimbalAxis(samples.rollNeutral, samples.rollTilted)
  return { pitch = pitch, roll = roll }
end
local function attitudeAccept(result)
  return result.pitch.status == "ok" and result.roll.status == "ok"
end
local function attitudeApply(cfg, result)
  calibrate.applyGimbal(cfg, "pitch", result.pitch)
  calibrate.applyGimbal(cfg, "roll", result.roll)
  return cfg
end

-- ---- lateral: cal.classifyLateralPair(neutral, sway, yaw) ----
local function lateralCapture(samples)
  return cal.classifyLateralPair(samples.neutral, samples.sway, samples.yaw)
end
local function lateralAccept(result)
  return result.swayOk and result.yawOk
end
local function lateralApply(cfg, result)
  return calibrate.applyLateral(cfg, result)
end

-- ---- surge: cal.classifyScalarSign(0, peakV) where peakV is the peak of (reading - neutral) ----
local function surgeCapture(samples)
  local offs = {}
  for i, r in ipairs(samples.readings) do offs[i] = r - (samples.neutral or 0) end
  local peakV = calibrate.peakByAbs(offs)
  return cal.classifyScalarSign(0, peakV)
end
local function surgeAccept(result)
  return result.status == "ok"
end
local function surgeApply(cfg, result)
  return calibrate.applyScalarSign(cfg, "signVelMedial", result.sign)
end

-- ---- heading: cal.headingSignScale(neutral, final, yawPeak-during-the-SAME-rotation) ----
local function headingCapture(samples)
  local n = calibrate.average(samples.neutralReadings)
  local heads = samples.rotation.headings
  local m = heads[#heads]
  local yawPeak = calibrate.peakByAbs(samples.rotation.yaws)
  return cal.headingSignScale(n, m, yawPeak)
end
local function headingAccept(result)
  return result.status == "ok"
end
local function headingApply(cfg, result)
  return calibrate.applyHeading(cfg, result)
end

-- ---- ground: cal.computeHeightOffset / cal.computeGroundThreshold ----
local function groundCapture(samples)
  local rawAlt = calibrate.average(samples.altReadings)
  local optD = calibrate.average(samples.optReadings)
  local off = cal.computeHeightOffset(rawAlt, samples.baroThrusterOffset or 0)
  local thr = cal.computeGroundThreshold(optD)
  return { heightOffset = off, onGroundThreshold = thr }
end
local function groundAccept(_result)
  return true -- terminal tool's stepGround has no computed status, only a manual accept? (y/n)
end
local function groundApply(cfg, result)
  return calibrate.applyGround(cfg, result.heightOffset, result.onGroundThreshold)
end

-- ---- constants: operator-entered numbers, no classify call ----
local function constantsCapture(samples)
  return { yawBaseline = samples.yawBaseline, baroThrusterOffset = samples.baroThrusterOffset }
end
local function constantsAccept(_result)
  return true -- terminal tool's stepConstants has no gating either
end
local function constantsApply(cfg, result)
  return calibrate.applyConstants(cfg, result.yawBaseline, result.baroThrusterOffset)
end

-- ===== M.steps(): fresh ordered list every call. PURE -- no shared mutable state. =====
function M.steps()
  return {
    {
      id = "attitude", label = "ATTITUDE (PITCH+ROLL)",
      prompts = {
        "Hold craft LEVEL, press CAPTURE (pitch neutral)",
        "Tilt NOSE UP ~20 deg and HOLD, press CAPTURE",
        "Hold craft LEVEL, press CAPTURE (roll neutral)",
        "Roll RIGHT WING DOWN ~20 deg and HOLD, press CAPTURE",
      },
      capture = attitudeCapture, accept = attitudeAccept, apply = attitudeApply,
    },
    {
      id = "lateral", label = "LATERAL",
      prompts = {
        "Hold still, press CAPTURE (neutral)",
        "SHOVE craft to its RIGHT, press CAPTURE then shove for 3s",
        "YAW nose to the RIGHT, press CAPTURE then yaw for 3s",
      },
      capture = lateralCapture, accept = lateralAccept, apply = lateralApply,
    },
    {
      id = "surge", label = "SURGE",
      prompts = {
        "Hold still, press CAPTURE (neutral)",
        "SHOVE craft FORWARD, press CAPTURE then shove for 3s",
      },
      capture = surgeCapture, accept = surgeAccept, apply = surgeApply,
    },
    {
      id = "heading", label = "HEADING",
      prompts = {
        "Face craft at reference heading, hold still, press CAPTURE",
        "Rotate NOSE ~90 deg to the RIGHT over ~3s -- KEEP IT MOVING, press CAPTURE",
      },
      capture = headingCapture, accept = headingAccept, apply = headingApply,
    },
    {
      id = "ground", label = "GROUND",
      prompts = {
        "Set craft ON THE GROUND at rest, press CAPTURE (altimeter)",
        "Set craft ON THE GROUND at rest, press CAPTURE (optical)",
      },
      capture = groundCapture, accept = groundAccept, apply = groundApply,
    },
    {
      id = "constants", label = "CONSTANTS",
      prompts = {
        "yawBaseline (fore/aft sensor spacing, blocks)",
        "baroThrusterOffset (+ = baro above thrusters, blocks)",
      },
      capture = constantsCapture, accept = constantsAccept, apply = constantsApply,
    },
  }
end

-- ===== M._save: TESTABLE, Basalt-free seam. =====
function M._save(cfg, write)
  return cfgspec.save("senscal", cfg.bindings, write)
end

-- =====================================================================================
-- ===== BASALT RUNNER: per-phase sampling reducers + the real (non-test) sampler.   =====
-- =====================================================================================

local function readNum(p, method)
  if not p then return 0 end
  local v = p[method](); return v or 0
end

-- yawRate exactly as tools/calibrate.lua's local readYawRate computes it (and as
-- fcs/io/backend.lua does at runtime), so heading's cross-check sampler sees the SAME signal.
local function readYawRate(vf, vr, b)
  local vfv = (b.signVelFront or 1) * readNum(vf, "getVelocity")
  local vrv = (b.signVelRear or 1) * readNum(vr, "getVelocity")
  local base = (b.yawBaseline and b.yawBaseline ~= 0) and b.yawBaseline or 1
  return (b.signYawRate or 1) * (vfv - vrv) / base
end

local function reduceAvgAngles(rawStream)
  local a, b = {}, {}
  for i, s in ipairs(rawStream) do a[i] = s[1] or 0; b[i] = s[2] or 0 end
  return { calibrate.average(a), calibrate.average(b) }
end

local function reduceAvgPair(rawStream)
  local f, r = {}, {}
  for i, s in ipairs(rawStream) do f[i] = s.front or 0; r[i] = s.rear or 0 end
  return { front = calibrate.average(f), rear = calibrate.average(r) }
end

-- Mirrors tools/calibrate.lua's local peak(samples, proj): pick the raw sample whose
-- proj(front-nF, rear-nR) has the largest magnitude, via calibrate.argmaxAbs (M.argmaxAbs).
local function reducePeakPair(proj)
  return function(rawStream, soFar)
    local base = (soFar and soFar.neutral) or { front = 0, rear = 0 }
    local vals = {}
    for i, s in ipairs(rawStream) do
      vals[i] = proj((s.front or 0) - (base.front or 0), (s.rear or 0) - (base.rear or 0))
    end
    return rawStream[calibrate.argmaxAbs(vals)] or base
  end
end

local function reduceIdentity(rawStream) return rawStream end

local function reduceHeadingRotation(rawStream)
  local heads, yaws = {}, {}
  for i, s in ipairs(rawStream) do heads[i] = s.heading or 0; yaws[i] = s.yaw or 0 end
  return { headings = heads, yaws = yaws }
end

-- PHASE_SPECS: per-step ordered phase list driving the CAPTURE flow. Each "stream" phase names
-- the devbind sensor keys it needs, a duration (seconds), and a reduce(rawStream, phaseSamplesSoFar)
-- that turns the raw stream into that phase's contribution to `samples[key]` -- purely a UI-side
-- convenience for assembling the SAME `samples` shape the pure capture() functions above expect;
-- it never touches classify/apply logic itself. "numeric" phases (constants step only) have no
-- sensors -- the operator adjusts a value with +/- and CAPTURE just records it.
local PHASE_SPECS = {
  attitude = {
    { key = "pitchNeutral", kind = "stream", duration = 1, sensors = { "gimbal" }, reduce = reduceAvgAngles },
    { key = "pitchTilted",  kind = "stream", duration = 1, sensors = { "gimbal" }, reduce = reduceAvgAngles },
    { key = "rollNeutral",  kind = "stream", duration = 1, sensors = { "gimbal" }, reduce = reduceAvgAngles },
    { key = "rollTilted",   kind = "stream", duration = 1, sensors = { "gimbal" }, reduce = reduceAvgAngles },
  },
  lateral = {
    { key = "neutral", kind = "stream", duration = 1, sensors = { "velFront", "velRear" }, reduce = reduceAvgPair },
    { key = "sway",     kind = "stream", duration = 3, sensors = { "velFront", "velRear" },
      reduce = reducePeakPair(function(df, dr) return df + dr end) },
    { key = "yaw",      kind = "stream", duration = 3, sensors = { "velFront", "velRear" },
      reduce = reducePeakPair(function(df, dr) return df - dr end) },
  },
  surge = {
    { key = "neutral",  kind = "stream", duration = 1, sensors = { "velMedial" }, reduce = function(s) return calibrate.average(s) end },
    { key = "readings", kind = "stream", duration = 3, sensors = { "velMedial" }, reduce = reduceIdentity },
  },
  heading = {
    { key = "neutralReadings", kind = "stream", duration = 1, sensors = { "navTable" }, reduce = reduceIdentity },
    { key = "rotation",        kind = "stream", duration = 3, sensors = { "navTable", "velFront", "velRear" }, reduce = reduceHeadingRotation },
  },
  ground = {
    { key = "altReadings", kind = "stream", duration = 1, sensors = { "altimeter" },   reduce = reduceIdentity },
    { key = "optReadings", kind = "stream", duration = 1, sensors = { "downOptical" }, reduce = reduceIdentity },
  },
  constants = {
    { key = "yawBaseline",         kind = "numeric", step = 1, cfgKey = "yawBaseline" },
    { key = "baroThrusterOffset",  kind = "numeric", step = 1, cfgKey = "baroThrusterOffset" },
  },
}
M._PHASE_SPECS = PHASE_SPECS

-- =====================================================================================
-- ===== M.newController: Basalt-free step-runner state machine.                     =====
-- ===== TESTABLE without Basalt/schedule/sleep -- the ONLY thing it does NOT do is    =====
-- ===== sampling itself: the caller (M.build's CAPTURE handler, or a test) hands it   =====
-- ===== an already-collected raw stream for "stream" phases via :captureStream(raw).  =====
-- =====================================================================================
-- cfg: {bindings=...} working senscal cfg (a defaults-scaffolded flat bindings table, e.g.
--      cfgspec.merge("senscal", cfgspec.load("senscal", read))). steps: M.steps()'s result.
function M.newController(cfg, steps)
  local self = { cfg = cfg, steps = steps, stepIdx = 1, phaseIdx = 1, phaseSamples = {}, result = nil, numericValue = 0 }
  local C = {}

  local function phases() return PHASE_SPECS[self.steps[self.stepIdx].id] end
  local function curPhase() return phases()[self.phaseIdx] end

  function C.step() return self.steps[self.stepIdx] end
  function C.phase() return curPhase() end
  function C.phases() return phases() end
  function C.stepIdx() return self.stepIdx end
  function C.phaseIdx() return self.phaseIdx end
  function C.result() return self.result end
  function C.cfg() return self.cfg end
  function C.numericValue() return self.numericValue end

  local function resetStepState()
    self.phaseIdx = 1
    self.phaseSamples = {}
    self.result = nil
    local p = curPhase()
    if p and p.kind == "numeric" then self.numericValue = self.cfg.bindings[p.cfgKey] or 0 end
  end
  C.resetStepState = resetStepState
  resetStepState()

  local function finishPhase()
    local ps = phases()
    if self.phaseIdx < #ps then
      self.phaseIdx = self.phaseIdx + 1
      local p = curPhase()
      if p.kind == "numeric" then self.numericValue = self.cfg.bindings[p.cfgKey] or 0 end
    else
      local step = C.step()
      local samples = self.phaseSamples
      if step.id == "ground" then samples.baroThrusterOffset = self.cfg.bindings.baroThrusterOffset end
      self.result = step.capture(samples)
    end
  end

  -- Capture the current STREAM phase given its already-sampled raw stream. Sampling itself
  -- (peripheral reads + sleep-loop timing) is the Basalt runner's job -- see M.build's
  -- captureBtn handler, which gathers `raw` on a basalt.schedule coroutine via the injected
  -- sampler and then calls this.
  function C.captureStream(rawStream)
    local p = curPhase()
    if not p or p.kind ~= "stream" then return end
    self.phaseSamples[p.key] = p.reduce(rawStream, self.phaseSamples)
    finishPhase()
  end

  -- Capture the current NUMERIC phase's value (constants step only).
  function C.captureNumeric()
    local p = curPhase()
    if not p or p.kind ~= "numeric" then return end
    self.phaseSamples[p.key] = self.numericValue
    finishPhase()
  end

  function C.adjustNumeric(delta)
    local p = curPhase()
    if p and p.kind == "numeric" then self.numericValue = self.numericValue + delta * (p.step or 1) end
  end

  -- Accept the computed result (if any) and gated ok by step.accept: applies it (step.apply,
  -- via the SAME M.apply* helpers tools/calibrate.lua's terminal steps use) and advances to the
  -- next step. Returns true iff it actually advanced.
  function C.accept()
    local step = C.step()
    if self.result ~= nil and step.accept(self.result) then
      self.cfg = step.apply(self.cfg, self.result)
      if self.stepIdx < #self.steps then self.stepIdx = self.stepIdx + 1 end
      resetStepState()
      return true
    end
    return false
  end

  function C.reject() resetStepState() end

  function C.nextStep()
    if self.stepIdx < #self.steps then self.stepIdx = self.stepIdx + 1 end
    resetStepState()
  end
  function C.prevStep()
    if self.stepIdx > 1 then self.stepIdx = self.stepIdx - 1 end
    resetStepState()
  end

  return C
end

-- realSampler(stepId, phase, wrapped, cfg) -> raw stream for that phase. Uses calibrate.stream
-- (tools/calibrate.lua's M.stream) so the sleep-loop sampling is REUSED, not reimplemented.
-- `wrapped` is a { sensorKey -> wrapped peripheral (or nil) } table for phase.sensors.
local function realSampler(stepId, phase, wrapped, cfg)
  if stepId == "attitude" then
    return calibrate.stream(function()
      local g = wrapped.gimbal
      return (g and g.getAngles()) or { 0, 0 }
    end, phase.duration)
  elseif stepId == "lateral" then
    return calibrate.stream(function()
      return { front = readNum(wrapped.velFront, "getVelocity"), rear = readNum(wrapped.velRear, "getVelocity") }
    end, phase.duration)
  elseif stepId == "surge" then
    return calibrate.stream(function()
      return readNum(wrapped.velMedial, "getVelocity")
    end, phase.duration)
  elseif stepId == "heading" then
    if phase.key == "neutralReadings" then
      return calibrate.stream(function()
        return readNum(wrapped.navTable, "getRelativeAngle")
      end, phase.duration)
    else
      local b = cfg.bindings
      return calibrate.stream(function()
        return { heading = readNum(wrapped.navTable, "getRelativeAngle"), yaw = readYawRate(wrapped.velFront, wrapped.velRear, b) }
      end, phase.duration)
    end
  elseif stepId == "ground" then
    if phase.key == "altReadings" then
      return calibrate.stream(function()
        return readNum(wrapped.altimeter, "getHeight")
      end, phase.duration)
    else
      return calibrate.stream(function()
        return readNum(wrapped.downOptical, "getDistance")
      end, phase.duration)
    end
  end
  return {}
end
M._realSampler = realSampler

-- ===== real fs read/write (default injected seams; never called at module load) =====

local function realRead(filename)
  local path = "/" .. filename
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local body = f.readAll()
  f.close()
  return body
end

-- Atomic tmp-then-move write, mirrors ui/basalt/bitconfig/tuning.lua's realWrite exactly.
local function realWrite(filename, body)
  local path = "/" .. filename
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  f.write(body)
  f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
end

-- ===== M.build: construct the step-runner element tree =====

function M.build(basalt, frame, runtime, nav, read, write, sampler)
  read = read or realRead
  write = write or realWrite
  sampler = sampler or realSampler

  local steps = M.steps()
  local sensorNames = (cfgspec.load("devbind", read)).sensors
  local cfg = { bindings = cfgspec.merge("senscal", cfgspec.load("senscal", read)) }

  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local headerLabel = frame:addLabel({ x = x, y = 2, width = iw, height = 1, autoSize = false, text = M.title })
  local promptLabel = frame:addLabel({ x = x, y = 3, width = iw, height = 1, autoSize = false, text = "" })
  local statusLabel = frame:addLabel({ x = x, y = 4, width = iw, height = 1, autoSize = false, text = "" })
  local valueLabel  = frame:addLabel({ x = x, y = 5, width = iw, height = 1, autoSize = false, text = "" })

  local halfW = math.max(1, math.floor(iw / 2))
  local minusBtn   = frame:addButton({ x = x,          y = 6, width = 4, height = 1, text = "-" })
  local plusBtn    = frame:addButton({ x = x + 4,       y = 6, width = 4, height = 1, text = "+" })
  local captureBtn = frame:addButton({ x = x + 8,       y = 6, width = math.max(1, iw - 8), height = 1, text = "CAPTURE" })

  local acceptBtn = frame:addButton({ x = x,        y = 7, width = halfW, height = 1, text = "ACCEPT" })
  local rejectBtn = frame:addButton({ x = x + halfW, y = 7, width = math.max(1, iw - halfW), height = 1, text = "REJECT" })

  local prevBtn = frame:addButton({ x = x,        y = 8, width = halfW, height = 1, text = "< STEP" })
  local nextBtn = frame:addButton({ x = x + halfW, y = 8, width = math.max(1, iw - halfW), height = 1, text = "STEP >" })

  local thirdW = math.max(1, math.floor(iw / 3))
  local saveBtn = frame:addButton({ x = x,             y = 9, width = thirdW, height = 1, text = "SAVE" })
  local backBtn = frame:addButton({ x = x + 2 * thirdW, y = 9, width = math.max(1, iw - 2 * thirdW), height = 1, text = "< BACK" })

  -- The step-runner STATE MACHINE lives in M.newController (Basalt-free, independently
  -- TESTABLE -- see tests/test_bitconfig_senscal.lua). M.build only wires Basalt elements to
  -- its methods and owns the one Basalt-specific piece: gathering a phase's raw sensor stream
  -- on a basalt.schedule coroutine before handing it to ctrl:captureStream(raw).
  local ctrl = M.newController(cfg, steps)

  local function wrapSensors(keys)
    local wrapped = {}
    for _, k in ipairs(keys) do
      local name = sensorNames[k]
      wrapped[k] = name and shim.wrap(name) or nil
    end
    return wrapped
  end

  local function refresh()
    local step = ctrl.step()
    headerLabel:setText(M.title .. "  STEP " .. ctrl.stepIdx() .. "/" .. #steps .. " " .. step.label)
    local prompt = step.prompts[ctrl.phaseIdx()] or ""
    promptLabel:setText(prompt)

    if ctrl.result() ~= nil then
      statusLabel:setText("captured -- ACCEPT or REJECT")
      captureBtn:setEnabled(false)
      minusBtn:setEnabled(false)
      plusBtn:setEnabled(false)
      acceptBtn:setEnabled(true)
      rejectBtn:setEnabled(true)
      valueLabel:setText("")
    else
      statusLabel:setText("phase " .. ctrl.phaseIdx() .. "/" .. #ctrl.phases())
      captureBtn:setEnabled(true)
      acceptBtn:setEnabled(false)
      rejectBtn:setEnabled(false)
      local phase = ctrl.phase()
      if phase and phase.kind == "numeric" then
        minusBtn:setEnabled(true)
        plusBtn:setEnabled(true)
        valueLabel:setText(tostring(ctrl.numericValue()))
        captureBtn:setText("SET")
      else
        minusBtn:setEnabled(false)
        plusBtn:setEnabled(false)
        valueLabel:setText("")
        captureBtn:setText("CAPTURE")
      end
    end
  end

  captureBtn:onClick(function()
    local phase = ctrl.phase()
    if not phase then return end
    if phase.kind == "numeric" then
      ctrl.captureNumeric()
      refresh()
      return
    end
    local step = ctrl.step()
    basalt.schedule(function()
      local wrapped = wrapSensors(phase.sensors)
      local raw = sampler(step.id, phase, wrapped, ctrl.cfg())
      ctrl.captureStream(raw)
      refresh()
    end)
  end)

  minusBtn:onClick(function() ctrl.adjustNumeric(-1); refresh() end)
  plusBtn:onClick(function() ctrl.adjustNumeric(1); refresh() end)

  acceptBtn:onClick(function() ctrl.accept(); refresh() end)
  rejectBtn:onClick(function() ctrl.reject(); refresh() end)

  prevBtn:onClick(function() ctrl.prevStep(); refresh() end)
  nextBtn:onClick(function() ctrl.nextStep(); refresh() end)

  saveBtn:onClick(function()
    M._save(ctrl.cfg(), write)
  end)
  backBtn:onClick(function()
    if nav then nav:pop() end
  end)

  refresh()

  -- apply(state): this menu shows a guided CONFIG flow, not live telemetry -- an idempotent
  -- repaint of the current step/phase is all that's needed (never polls peripherals on its own;
  -- CAPTURE is the only thing that samples, and only on click, on a scheduled coroutine).
  local function apply(_state)
    refresh()
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      headerLabel = headerLabel, promptLabel = promptLabel, statusLabel = statusLabel, valueLabel = valueLabel,
      minusBtn = minusBtn, plusBtn = plusBtn, captureBtn = captureBtn,
      acceptBtn = acceptBtn, rejectBtn = rejectBtn,
      prevBtn = prevBtn, nextBtn = nextBtn,
      saveBtn = saveBtn, backBtn = backBtn,
    },
  }
end

return M
