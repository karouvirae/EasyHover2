# Sensor Calibration (Plan 7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a guided in-game procedure that measures every sensor sign/axis/unit against plunger-induced motions and writes them to the hardware config the backend loads.

**Architecture:** A pure, headless-tested inference core (`fcs/io/calibration.lua`) classifies axis/sign/unit from before/after sensor snapshots, robust to impure motions (dominant-channel selection, confidence gate, common/differential decoupling). A thin in-game UI (`tools/calibrate.lua`) captures snapshots, calls the core, and writes `/eh2_hw_config.tbl`. The backend gains surgical wiring to apply the new bindings. Delivery piggybacks the existing probe installer.

**Tech Stack:** CC:Tweaked Lua 5.1, CraftOS-PC headless test harness, existing `tests/framework.lua`.

## Global Constraints

- **Lua 5.1** (CC:Tweaked runtime) — no goto, no integer division, no `#` on nil.
- **Wrapped peripherals take NO `self`** — call `p.getAngles()` / `p.getVelocity()`, never `p:getAngles()`.
- **Prints are ASCII-only** (real CC font is ASCII; no unicode glyphs/degree symbols — write "deg").
- **Tests run via** `bash tests/run_headless.sh` (runs ALL suites; there is no single-test runner). New suites MUST be added to the `suites` table AND the require list in that script's `startup.lua` heredoc.
- **Config is additive** — new bindings go through `hwconfig.defaults()` + `hwconfig.merge`; never break existing keys.
- **Backend binding reads use `or` fallbacks** (e.g. `(b.signHeading or 1)`) so old configs and existing tests keep passing.
- **No external dependencies.** Test API is only `t.test/t.eq/t.near/t.truthy`.
- **Sign convention (ground truth):** sensors read **+** when: pitch = nose UP, roll = right wing DOWN, heading/yawRate = nose rotating RIGHT, swayVel = moving RIGHT, surgeVel = moving FORWARD, altitude = higher.

## File Structure

- Create `fcs/io/calibration.lua` — pure inference core (Tasks 1–4).
- Create `tests/test_calibration.lua` — headless tests for the core (Tasks 1–4).
- Modify `fcs/io/backend.lua` — apply new sign/scale/offset bindings in `sensors()` (Task 5).
- Modify `fcs/io/hwconfig.lua` — defaults for new bindings (Task 5).
- Modify `tests/test_backend.lua` — cover the new wiring (Task 5).
- Create `tools/calibrate.lua` — pure apply/reducer helpers (Task 6) + interactive `run()` (Task 7).
- Create `tests/test_calibrate.lua` — headless tests for the pure helpers (Task 6).
- Modify `tests/run_headless.sh` — register `test_calibration` (Task 1) and `test_calibrate` (Task 6).
- Modify `tools/install_probe.lua` — fetch the two new files + write `/calibrate` launcher (Task 8).

---

### Task 1: Core scaffolding — `gate` + `classifyScalarSign`

**Files:**
- Create: `fcs/io/calibration.lua`
- Test: `tests/test_calibration.lua`
- Modify: `tests/run_headless.sh` (register the new suite)

**Interfaces:**
- Produces:
  - `M.FLOOR` (0.02), `M.RATIO` (3.0), `M.GIMBAL_DEG` (3.0), `M.HEADING_DEG` (10.0) — shared tunables.
  - `M.gate(dominant, runnerUp, floor?, ratio?) -> "ok"|"too-small"|"too-ambiguous"` (magnitudes; `floor`/`ratio` default to the module constants).
  - `M.classifyScalarSign(neutralVal, sampleVal, opts?) -> {sign, magnitude, status}` (`opts.floor` optional).

- [ ] **Step 1: Write the failing test** — create `tests/test_calibration.lua`:

```lua
local t = require("tests.framework")
local cal = require("fcs.io.calibration")

t.test("gate: dominant below floor is too-small", function()
  t.eq(cal.gate(0.001, 0, 0.02, 3), "too-small")
end)
t.test("gate: dominant not beating runner-up by ratio is too-ambiguous", function()
  t.eq(cal.gate(0.20, 0.15, 0.02, 3), "too-ambiguous")   -- 0.20 < 3*0.15
end)
t.test("gate: clear dominant with tiny runner-up is ok", function()
  t.eq(cal.gate(0.40, 0.03, 0.02, 3), "ok")              -- 0.40 > 3*0.03
end)
t.test("gate: zero runner-up above floor is ok", function()
  t.eq(cal.gate(0.40, 0, 0.02, 3), "ok")
end)
t.test("gate: uses module defaults when floor/ratio omitted", function()
  t.eq(cal.gate(0.001, 0), "too-small")
end)
t.test("classifyScalarSign: positive delta -> +1", function()
  local r = cal.classifyScalarSign(0, 3.0)
  t.eq(r.sign, 1); t.eq(r.status, "ok"); t.near(r.magnitude, 3.0, 1e-9)
end)
t.test("classifyScalarSign: negative delta -> -1", function()
  t.eq(cal.classifyScalarSign(1.0, -2.0).sign, -1)
end)
t.test("classifyScalarSign: sub-floor delta is too-small", function()
  t.eq(cal.classifyScalarSign(0, 0.001).status, "too-small")
end)
```

- [ ] **Step 2: Register the suite** — in `tests/run_headless.sh`, add `"tests.test_calibration"` to the end of the `suites` table inside the `startup.lua` heredoc:

```lua
"tests.test_backend", "tests.test_backend_dropin", "tests.test_probe", "tests.test_calibration" }
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — a `SUITE LOAD FAILURES` entry for `tests.test_calibration` (module not found yet).

- [ ] **Step 4: Write minimal implementation** — create `fcs/io/calibration.lua`:

```lua
local M = {}

-- Shared tunables (UI and tests reference these).
M.FLOOR = 0.02        -- minimum dominant magnitude to trust a motion
M.RATIO = 3.0         -- dominant must beat runner-up by this factor
M.GIMBAL_DEG = 3.0    -- |delta| above this => gimbal emits degrees, not radians
M.HEADING_DEG = 10.0  -- |delta| above this => heading emits degrees

local function signOf(x) return x >= 0 and 1 or -1 end
M._signOf = signOf

function M.gate(dominant, runnerUp, floor, ratio)
  floor = floor or M.FLOOR; ratio = ratio or M.RATIO
  dominant = math.abs(dominant); runnerUp = math.abs(runnerUp)
  if dominant < floor then return "too-small" end
  if runnerUp > 0 and dominant < ratio * runnerUp then return "too-ambiguous" end
  return "ok"
end

function M.classifyScalarSign(neutralVal, sampleVal, opts)
  opts = opts or {}
  local floor = opts.floor or M.FLOOR
  local d = sampleVal - neutralVal
  return { sign = signOf(d), magnitude = math.abs(d),
           status = math.abs(d) >= floor and "ok" or "too-small" }
end

return M
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — all suites pass, including the new `tests.test_calibration` cases.

- [ ] **Step 6: Commit**

```bash
git add fcs/io/calibration.lua tests/test_calibration.lua tests/run_headless.sh
git commit -m "feat(cal): calibration core scaffolding — gate + scalar sign classifier"
```

---

### Task 2: `classifyGimbalAxis` (dominant channel + unit detection)

**Files:**
- Modify: `fcs/io/calibration.lua`
- Test: `tests/test_calibration.lua`

**Interfaces:**
- Consumes: `M.gate`, `M.GIMBAL_DEG`, `signOf`.
- Produces: `M.classifyGimbalAxis(neutral, moved, opts?) -> {idx, sign, unit, scale, dominant, runnerUp, status}`.
  `neutral`/`moved` are 2-element raw angle arrays `{a, b}`. `idx` is the dominant channel (1 or 2); `sign` its direction; `unit` is `"deg"` or `"rad"`; `scale` is `math.pi/180` for deg else `1`. `opts` may set `floor`, `ratio`, `degThreshold`.

- [ ] **Step 1: Write the failing test** — append to `tests/test_calibration.lua`:

```lua
t.test("classifyGimbalAxis: nose-up on channel 1 in radians", function()
  local r = cal.classifyGimbalAxis({0, 0}, {0.35, 0.01})
  t.eq(r.idx, 1); t.eq(r.sign, 1); t.eq(r.unit, "rad"); t.near(r.scale, 1, 1e-9)
  t.eq(r.status, "ok")
end)
t.test("classifyGimbalAxis: roll on channel 2, negative, in degrees", function()
  local r = cal.classifyGimbalAxis({0, 0}, {0.2, -22.0})
  t.eq(r.idx, 2); t.eq(r.sign, -1); t.eq(r.unit, "deg")
  t.near(r.scale, math.pi/180, 1e-9); t.eq(r.status, "ok")
end)
t.test("classifyGimbalAxis: pitch with 20pct roll bleed still resolves to pitch", function()
  local r = cal.classifyGimbalAxis({0, 0}, {0.40, 0.08})   -- 0.40 vs 0.08 = 5x
  t.eq(r.idx, 1); t.eq(r.sign, 1); t.eq(r.status, "ok")
end)
t.test("classifyGimbalAxis: too-close channels are rejected as too-ambiguous", function()
  local r = cal.classifyGimbalAxis({0, 0}, {0.22, 0.15})   -- 0.22 < 3*0.15
  t.eq(r.status, "too-ambiguous")
end)
t.test("classifyGimbalAxis: no real motion is too-small", function()
  t.eq(cal.classifyGimbalAxis({0, 0}, {0.001, -0.001}).status, "too-small")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — new cases error with "classifyGimbalAxis: attempt to call a nil value".

- [ ] **Step 3: Write implementation** — add to `fcs/io/calibration.lua` before `return M`:

```lua
function M.classifyGimbalAxis(neutral, moved, opts)
  opts = opts or {}
  local degT = opts.degThreshold or M.GIMBAL_DEG
  local d1 = (moved[1] or 0) - (neutral[1] or 0)
  local d2 = (moved[2] or 0) - (neutral[2] or 0)
  local idx, dom, other
  if math.abs(d1) >= math.abs(d2) then idx, dom, other = 1, d1, d2
  else idx, dom, other = 2, d2, d1 end
  local unit = math.abs(dom) > degT and "deg" or "rad"
  local scale = unit == "deg" and (math.pi / 180) or 1
  return { idx = idx, sign = signOf(dom), unit = unit, scale = scale,
           dominant = math.abs(dom), runnerUp = math.abs(other),
           status = M.gate(dom, other, opts.floor, opts.ratio) }
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — all suites pass.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/calibration.lua tests/test_calibration.lua
git commit -m "feat(cal): gimbal axis classifier — dominant channel, unit detection, gate"
```

---

### Task 3: `classifyLateralPair` (common/differential decoupling)

**Files:**
- Modify: `fcs/io/calibration.lua`
- Test: `tests/test_calibration.lua`

**Interfaces:**
- Consumes: `M.gate`, `signOf`.
- Produces: `M.classifyLateralPair(neutral, swaySample, yawSample, opts?) -> {signFront, signRear, signYawRate, swayStatus, yawStatus, swayOk, yawOk}`.
  Each of `neutral`/`swaySample`/`yawSample` is `{front=<num>, rear=<num>}` of raw velocity readings. Per-sensor signs come from the sway (common-mode-dominant) sample; `signYawRate` from the differential of the sign-normalized yaw sample.

- [ ] **Step 1: Write the failing test** — append to `tests/test_calibration.lua`:

```lua
local NZ = {front=0, rear=0}
t.test("classifyLateralPair: clean rightward sway sets both signs +", function()
  -- both sensors read + for rightward; yaw: front +, rear - (nose-right)
  local r = cal.classifyLateralPair(NZ, {front=2.0, rear=2.0}, {front=2.0, rear=-2.0})
  t.eq(r.signFront, 1); t.eq(r.signRear, 1); t.eq(r.signYawRate, 1)
  t.eq(r.swayOk, true); t.eq(r.yawOk, true)
end)
t.test("classifyLateralPair: an inverted rear sensor is caught", function()
  -- rear sensor wired inverted: reads - for rightward sway
  local r = cal.classifyLateralPair(NZ, {front=2.0, rear=-2.0}, {front=2.0, rear=2.0})
  t.eq(r.signFront, 1); t.eq(r.signRear, -1)
end)
t.test("classifyLateralPair: yaw contaminated with sway still yields clean yaw sign", function()
  -- nose-right yaw (front +, rear -) plus 30pct common sway drift (+0.6 both)
  local r = cal.classifyLateralPair(NZ, {front=2.0, rear=2.0},
                                        {front=2.6, rear=-1.4})   -- diff=4.0 dominates comm=1.2
  t.eq(r.signYawRate, 1); t.eq(r.yawOk, true)
end)
t.test("classifyLateralPair: a mostly-yaw sway sample is rejected (swayOk false)", function()
  local r = cal.classifyLateralPair(NZ, {front=2.0, rear=-2.0}, {front=2.0, rear=-2.0})
  t.eq(r.swayOk, false)   -- sway sample had no common-mode
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — "classifyLateralPair: attempt to call a nil value".

- [ ] **Step 3: Write implementation** — add to `fcs/io/calibration.lua` before `return M`:

```lua
function M.classifyLateralPair(neutral, swaySample, yawSample, opts)
  opts = opts or {}
  local floor, ratio = opts.floor, opts.ratio
  local sf = (swaySample.front or 0) - (neutral.front or 0)
  local sr = (swaySample.rear  or 0) - (neutral.rear  or 0)
  local yf = (yawSample.front or 0) - (neutral.front or 0)
  local yr = (yawSample.rear  or 0) - (neutral.rear  or 0)
  -- per-sensor sign from the sway sample: each sensor must read + for rightward
  local signFront, signRear = signOf(sf), signOf(sr)
  -- sway sample must be common-mode dominant (|sum| beats |difference|)
  local swayStatus = M.gate(sf + sr, sf - sr, floor, ratio)
  -- yaw sign from the differential of the sign-normalized yaw sample
  local diff = signFront * yf - signRear * yr
  local comm = signFront * yf + signRear * yr
  local yawStatus = M.gate(diff, comm, floor, ratio)
  return { signFront = signFront, signRear = signRear, signYawRate = signOf(diff),
           swayStatus = swayStatus, yawStatus = yawStatus,
           swayOk = swayStatus == "ok", yawOk = yawStatus == "ok" }
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — all suites pass.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/calibration.lua tests/test_calibration.lua
git commit -m "feat(cal): lateral pair classifier — common/differential decoupling"
```

---

### Task 4: heading scale + offset/threshold helpers

**Files:**
- Modify: `fcs/io/calibration.lua`
- Test: `tests/test_calibration.lua`

**Interfaces:**
- Consumes: `M.HEADING_DEG`, `signOf`.
- Produces:
  - `M.detectHeadingScale(neutralHeading, sampleHeading, opts?) -> {sign, scale, unit, magnitude, status}`.
  - `M.computeHeightOffset(groundRawAlt, baroThrusterOffset) -> number` (`-(groundRawAlt + baroThrusterOffset)`).
  - `M.computeGroundThreshold(opticalOnGround, margin?) -> number` (`opticalOnGround + (margin or 0.5)`).

- [ ] **Step 1: Write the failing test** — append to `tests/test_calibration.lua`:

```lua
t.test("detectHeadingScale: 90 deg rotation detected as degrees, sign +", function()
  local r = cal.detectHeadingScale(0, 90)
  t.eq(r.unit, "deg"); t.near(r.scale, math.pi/180, 1e-9); t.eq(r.sign, 1); t.eq(r.status, "ok")
end)
t.test("detectHeadingScale: ~1.5 rad rotation detected as radians", function()
  local r = cal.detectHeadingScale(0, 1.5)
  t.eq(r.unit, "rad"); t.near(r.scale, 1, 1e-9); t.eq(r.sign, 1)
end)
t.test("detectHeadingScale: leftward rotation gives sign -1", function()
  t.eq(cal.detectHeadingScale(0, -85).sign, -1)
end)
t.test("computeHeightOffset: zeroes rest altitude including baro-thruster offset", function()
  t.near(cal.computeHeightOffset(64, 3), -67, 1e-9)
end)
t.test("computeGroundThreshold: adds default margin", function()
  t.near(cal.computeGroundThreshold(0.5), 1.0, 1e-9)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — "detectHeadingScale: attempt to call a nil value".

- [ ] **Step 3: Write implementation** — add to `fcs/io/calibration.lua` before `return M`:

```lua
function M.detectHeadingScale(neutralHeading, sampleHeading, opts)
  opts = opts or {}
  local degT = opts.degThreshold or M.HEADING_DEG
  local floor = opts.floor or M.FLOOR
  local d = sampleHeading - neutralHeading
  local unit = math.abs(d) > degT and "deg" or "rad"
  local scale = unit == "deg" and (math.pi / 180) or 1
  return { sign = signOf(d), scale = scale, unit = unit, magnitude = math.abs(d),
           status = math.abs(d) >= floor and "ok" or "too-small" }
end

function M.computeHeightOffset(groundRawAlt, baroThrusterOffset)
  return -((groundRawAlt or 0) + (baroThrusterOffset or 0))
end

function M.computeGroundThreshold(opticalOnGround, margin)
  return (opticalOnGround or 0) + (margin or 0.5)
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — all suites pass.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/calibration.lua tests/test_calibration.lua
git commit -m "feat(cal): heading scale detection + height offset/ground threshold"
```

---

### Task 5: Backend wiring + hwconfig defaults

**Files:**
- Modify: `fcs/io/backend.lua:27-63` (`sensors()`)
- Modify: `fcs/io/hwconfig.lua:7-8` (`defaults().bindings`)
- Test: `tests/test_backend.lua`

**Interfaces:**
- Consumes: config `bindings` keys `signHeading`, `headingScale`, `signYawRate`, `gimbalScale`, `baroThrusterOffset` (all with `or` fallbacks).
- Produces: `sensors()` output where `heading = signHeading*headingScale*raw`, `yawRate = signYawRate*(vf-vr)/baseline`, `pitch/roll` scaled by `gimbalScale`, `altitude = raw + baroThrusterOffset + heightOffset`.

- [ ] **Step 1: Write the failing test** — append to `tests/test_backend.lua`:

```lua
t.test("heading applies sign and scale (deg->rad)", function()
  local cfg = sensorCfg(); cfg.bindings.signHeading = -1; cfg.bindings.headingScale = math.pi/180
  local b = Backend.new(sensorRig(10, {0,0}, 0,0,0, 90, 5), cfg, function() return 0 end)
  t.near(b:sensors().heading, -math.pi/2, 1e-6)   -- -1 * (pi/180) * 90
end)
t.test("gimbalScale converts pitch/roll from degrees", function()
  local cfg = sensorCfg(); cfg.bindings.gimbalScale = math.pi/180
  local b = Backend.new(sensorRig(10, {90,-90}, 0,0,0, 0, 5), cfg, function() return 0 end)
  t.near(b:sensors().pitch, math.pi/2, 1e-6); t.near(b:sensors().roll, -math.pi/2, 1e-6)
end)
t.test("signYawRate flips yaw-rate direction", function()
  local cfg = sensorCfg(); cfg.bindings.signYawRate = -1
  local b = Backend.new(sensorRig(10, {0,0}, 3, 1, 0, 0, 5), cfg, function() return 0 end)
  t.near(b:sensors().yawRate, -1, 1e-9)           -- -1 * (3-1)/2
end)
t.test("baroThrusterOffset adds into altitude", function()
  local cfg = sensorCfg(); cfg.bindings.baroThrusterOffset = 5
  local b = Backend.new(sensorRig(10, {0,0}, 0,0,0, 0, 5), cfg, function() return 0 end)
  t.near(b:sensors().altitude, 17, 1e-9)          -- 10 + 5 + heightOffset 2
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — heading is `90` not `-pi/2`; pitch is `90` not `pi/2`; yawRate is `1` not `-1`; altitude is `12` not `17`.

- [ ] **Step 3: Write implementation** — edit `fcs/io/backend.lua`. In `sensors()`:

Replace the altitude line:
```lua
  local altitude = rawAlt + (b.heightOffset or 0)
```
with:
```lua
  local altitude = rawAlt + (b.baroThrusterOffset or 0) + (b.heightOffset or 0)
```

Replace the pitch/roll lines:
```lua
  local pitch = (b.signPitch or 1) * (angles[b.gimbalPitchIdx or 1] or 0)
  local roll  = (b.signRoll  or 1) * (angles[b.gimbalRollIdx  or 2] or 0)
```
with:
```lua
  local gScale = b.gimbalScale or 1
  local pitch = (b.signPitch or 1) * gScale * (angles[b.gimbalPitchIdx or 1] or 0)
  local roll  = (b.signRoll  or 1) * gScale * (angles[b.gimbalRollIdx  or 2] or 0)
```

Replace the heading line:
```lua
  local heading = self:_read(c.sensors.navTable, "getRelativeAngle") or 0
```
with:
```lua
  local rawHeading = self:_read(c.sensors.navTable, "getRelativeAngle") or 0
  local heading = (b.signHeading or 1) * (b.headingScale or 1) * rawHeading
```

Replace the yaw-rate line:
```lua
  local yawRate = (vf - vr) / (baseline ~= 0 and baseline or 1)
```
with:
```lua
  local yawRate = (b.signYawRate or 1) * (vf - vr) / (baseline ~= 0 and baseline or 1)
```

- [ ] **Step 4: Add defaults** — in `fcs/io/hwconfig.lua`, replace the `bindings` line in `defaults()`:

```lua
    bindings = { heightOffset=0, onGroundThreshold=1.5, yawBaseline=1, vSpeedTau=0.3,
      gimbalPitchIdx=1, gimbalRollIdx=2, signPitch=1, signRoll=1, signVelFront=1, signVelRear=1, signVelMedial=1 },
```
with:
```lua
    bindings = { heightOffset=0, onGroundThreshold=1.5, yawBaseline=1, vSpeedTau=0.3,
      gimbalPitchIdx=1, gimbalRollIdx=2, gimbalScale=1, signPitch=1, signRoll=1,
      signVelFront=1, signVelRear=1, signVelMedial=1,
      signHeading=1, headingScale=1, signYawRate=1, baroThrusterOffset=0 },
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — new backend cases pass; existing backend/hwconfig cases still pass (defaults keep prior behavior: heading 0.3 -> 0.3, altitude 10+0+2 = 12).

- [ ] **Step 6: Commit**

```bash
git add fcs/io/backend.lua fcs/io/hwconfig.lua tests/test_backend.lua
git commit -m "feat(io): apply heading sign/scale, gimbal scale, yaw-rate sign, baro-thruster offset"
```

---

### Task 6: Calibrate tool — pure helpers (apply + reducers)

**Files:**
- Create: `tools/calibrate.lua` (pure-helpers portion; `run()` added in Task 7)
- Test: `tests/test_calibrate.lua`
- Modify: `tests/run_headless.sh` (register `test_calibrate`)

**Interfaces:**
- Consumes: `fcs.io.calibration` results.
- Produces (all on `M`, all pure):
  - `M.average(nums) -> number`
  - `M.peakByAbs(nums) -> number` (element with the largest absolute value; 0 for empty)
  - `M.argmaxAbs(nums) -> index` (1 for empty)
  - `M.applyGimbal(config, axis, result) -> config` (`axis` is `"pitch"` or `"roll"`; sets idx/sign + shared `gimbalScale`)
  - `M.applyLateral(config, result) -> config` (sets `signVelFront/Rear`, `signYawRate`)
  - `M.applyScalarSign(config, key, sign) -> config`
  - `M.applyHeading(config, result) -> config` (sets `signHeading`, `headingScale`)
  - `M.applyGround(config, heightOffset, threshold) -> config`
  - `M.applyConstants(config, yawBaseline, baroThrusterOffset) -> config`

- [ ] **Step 1: Write the failing test** — create `tests/test_calibrate.lua`:

```lua
local t = require("tests.framework")
local C = require("tools.calibrate")

local function cfg() return { thrusters={}, sensors={}, bindings={} } end

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
t.test("applyHeading writes sign and scale", function()
  local c = C.applyHeading(cfg(), {sign=-1, scale=math.pi/180})
  t.eq(c.bindings.signHeading, -1); t.near(c.bindings.headingScale, math.pi/180, 1e-9)
end)
t.test("applyGround writes height offset and threshold", function()
  local c = C.applyGround(cfg(), -67, 1.0)
  t.near(c.bindings.heightOffset, -67, 1e-9); t.near(c.bindings.onGroundThreshold, 1.0, 1e-9)
end)
t.test("applyConstants writes baseline and baro offset", function()
  local c = C.applyConstants(cfg(), 4, 5)
  t.near(c.bindings.yawBaseline, 4, 1e-9); t.near(c.bindings.baroThrusterOffset, 5, 1e-9)
end)
```

- [ ] **Step 2: Register the suite** — in `tests/run_headless.sh`, extend the `suites` table:

```lua
"tests.test_calibration", "tests.test_calibrate" }
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — `SUITE LOAD FAILURES` for `tests.test_calibrate` (module not found).

- [ ] **Step 4: Write implementation** — create `tools/calibrate.lua`:

```lua
-- EasyHover 2 — guided sensor calibration.
-- Pure helpers here are headless-tested; the interactive run() shell (added later)
-- is in-game only. Wrapped peripherals take NO self: p.getAngles(), p.getVelocity().
local cal = require("fcs.io.calibration")
local M = {}

function M.average(nums)
  if #nums == 0 then return 0 end
  local s = 0; for _, v in ipairs(nums) do s = s + v end
  return s / #nums
end

function M.peakByAbs(nums)
  local best = 0
  for _, v in ipairs(nums) do if math.abs(v) > math.abs(best) then best = v end end
  return best
end

function M.argmaxAbs(nums)
  local bi, bv = 1, -1
  for i, v in ipairs(nums) do if math.abs(v) > bv then bv = math.abs(v); bi = i end end
  return bi
end

function M.applyGimbal(config, axis, result)
  local b = config.bindings
  if axis == "pitch" then b.gimbalPitchIdx = result.idx; b.signPitch = result.sign
  else b.gimbalRollIdx = result.idx; b.signRoll = result.sign end
  b.gimbalScale = result.scale
  return config
end

function M.applyLateral(config, result)
  local b = config.bindings
  b.signVelFront = result.signFront; b.signVelRear = result.signRear; b.signYawRate = result.signYawRate
  return config
end

function M.applyScalarSign(config, key, sign) config.bindings[key] = sign; return config end

function M.applyHeading(config, result)
  local b = config.bindings
  b.signHeading = result.sign; b.headingScale = result.scale
  return config
end

function M.applyGround(config, heightOffset, threshold)
  local b = config.bindings
  b.heightOffset = heightOffset; b.onGroundThreshold = threshold
  return config
end

function M.applyConstants(config, yawBaseline, baroThrusterOffset)
  local b = config.bindings
  b.yawBaseline = yawBaseline; b.baroThrusterOffset = baroThrusterOffset
  return config
end

return M
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — all suites pass.

- [ ] **Step 6: Commit**

```bash
git add tools/calibrate.lua tests/test_calibrate.lua tests/run_headless.sh
git commit -m "feat(cal): calibrate tool pure helpers — reducers + config apply"
```

---

### Task 7: Calibrate tool — interactive `run()` shell

**Files:**
- Modify: `tools/calibrate.lua` (add config load/save + `run()`)

**Interfaces:**
- Consumes: `fcs.io.shim`, `fcs.io.hwconfig`, `fcs.io.calibration`, and the `M.apply*`/reducer helpers from Task 6. CC globals `read`, `write`, `print`, `sleep`, `os.epoch`, `fs`, `textutils`.
- Produces: `M.run()` — the in-game menu. No new automated tests (interactive); the require-load smoke in `tests/test_calibrate.lua` already guards that the file parses.

- [ ] **Step 1: Add config plumbing + sampling + run()** — insert into `tools/calibrate.lua` immediately before `return M`:

```lua
-- ---- interactive shell (in-game only) ----
local hwconfig = require("fcs.io.hwconfig")
local CONFIG_PATH = "/eh2_hw_config.tbl"

local function loadConfig()
  local saved
  if fs.exists(CONFIG_PATH) then
    local f = fs.open(CONFIG_PATH, "r"); saved = textutils.unserialise(f.readAll() or ""); f.close()
  end
  return hwconfig.merge(saved or {}, hwconfig.defaults())
end
local function saveConfig(c)
  local f = fs.open(CONFIG_PATH, "w"); f.write(textutils.serialise(c)); f.close()
end

local function readNum(p, method) if not p then return 0 end local v = p[method](); return v or 0 end

-- collect a reader's samples for ~secs seconds
local function stream(readerFn, secs)
  local out = {}; local t0 = os.epoch("utc")
  repeat out[#out+1] = readerFn(); sleep(0.1) until (os.epoch("utc") - t0) / 1000 >= secs
  return out
end

local function accept(result)
  print(("  status %s"):format(result.status or "ok"))
  if result.status and result.status ~= "ok" then
    print("  REJECTED (" .. result.status .. ") — redo bigger/cleaner"); return false
  end
  write("  accept? (y/n): "); return read() == "y"
end

local function stepAttitude(shim, config)
  local gim = shim.wrap(config.sensors.gimbal)
  if not gim then print("no gimbal bound"); return end
  local function angles() return gim.getAngles() or {0, 0} end
  for _, axis in ipairs({ "pitch", "roll" }) do
    local prompt = axis == "pitch" and "Tilt NOSE UP ~20 deg and HOLD" or "Roll RIGHT WING DOWN ~20 deg and HOLD"
    print("Hold craft LEVEL, press Enter for neutral"); read(); local n = angles()
    print(prompt .. ", press Enter"); read(); local m = angles()
    local r = cal.classifyGimbalAxis(n, m)
    print(("%s -> idx %d sign %d unit %s (%.3f vs %.3f)"):format(axis, r.idx, r.sign, r.unit, r.dominant, r.runnerUp))
    if accept(r) then M.applyGimbal(config, axis, r); saveConfig(config); print("  saved") end
  end
end

local function stepLateral(shim, config)
  local vf, vr = shim.wrap(config.sensors.velFront), shim.wrap(config.sensors.velRear)
  if not (vf and vr) then print("velFront/velRear not bound"); return end
  local nF, nR = readNum(vf, "getVelocity"), readNum(vr, "getVelocity")
  local function pair() return { front = readNum(vf, "getVelocity"), rear = readNum(vr, "getVelocity") } end
  local function peak(samples, proj)
    local vals = {}
    for i, s in ipairs(samples) do vals[i] = proj(s.front - nF, s.rear - nR) end
    return samples[M.argmaxAbs(vals)] or { front = nF, rear = nR }
  end
  print("SHOVE craft to its RIGHT, press Enter then shove for 3s"); read()
  local sway = peak(stream(pair, 3), function(df, dr) return df + dr end)
  print("YAW nose to the RIGHT, press Enter then yaw for 3s"); read()
  local yaw = peak(stream(pair, 3), function(df, dr) return df - dr end)
  local r = cal.classifyLateralPair({ front = nF, rear = nR }, sway, yaw)
  print(("front %d rear %d yawRate %d  sway[%s] yaw[%s]"):format(
    r.signFront, r.signRear, r.signYawRate, r.swayStatus, r.yawStatus))
  if r.swayOk and r.yawOk then
    write("  accept? (y/n): "); if read() == "y" then M.applyLateral(config, r); saveConfig(config); print("  saved") end
  else print("  REJECTED — sway must be a clean sideways shove, yaw a clean rotation") end
end

local function stepSurge(shim, config)
  local vm = shim.wrap(config.sensors.velMedial)
  if not vm then print("velMedial not bound"); return end
  local n = readNum(vm, "getVelocity")
  print("SHOVE craft FORWARD, press Enter then shove for 3s"); read()
  local peakV = M.peakByAbs(stream(function() return readNum(vm, "getVelocity") - n end, 3))
  local r = cal.classifyScalarSign(0, peakV)
  print(("surge sign %d (mag %.3f)"):format(r.sign, r.magnitude))
  if accept(r) then M.applyScalarSign(config, "signVelMedial", r.sign); saveConfig(config); print("  saved") end
end

local function stepHeading(shim, config)
  local nav = shim.wrap(config.sensors.navTable)
  if not nav then print("navTable not bound"); return end
  print("Face craft at reference heading, press Enter for neutral"); read()
  local n = readNum(nav, "getRelativeAngle")
  print("Rotate NOSE ~90 deg to the RIGHT and HOLD, press Enter"); read()
  local m = readNum(nav, "getRelativeAngle")
  local r = cal.detectHeadingScale(n, m)
  print(("heading sign %d unit %s (mag %.3f)"):format(r.sign, r.unit, r.magnitude))
  if accept(r) then M.applyHeading(config, r); saveConfig(config); print("  saved") end
end

local function stepGround(shim, config)
  local alt, opt = shim.wrap(config.sensors.altimeter), shim.wrap(config.sensors.downOptical)
  if not (alt and opt) then print("altimeter/downOptical not bound"); return end
  print("Set craft ON THE GROUND at rest, press Enter"); read()
  local rawAlt = readNum(alt, "getHeight")
  local optD = readNum(opt, "getDistance")
  local off = cal.computeHeightOffset(rawAlt, config.bindings.baroThrusterOffset or 0)
  local thr = cal.computeGroundThreshold(optD)
  print(("heightOffset %.3f  onGroundThreshold %.3f"):format(off, thr))
  write("  accept? (y/n): "); if read() == "y" then M.applyGround(config, off, thr); saveConfig(config); print("  saved") end
end

local function stepConstants(config)
  write("yawBaseline (fore/aft sensor spacing, blocks): "); local yb = tonumber(read()) or config.bindings.yawBaseline
  write("baroThrusterOffset (+ = baro above thrusters, blocks): "); local bo = tonumber(read()) or config.bindings.baroThrusterOffset
  M.applyConstants(config, yb, bo); saveConfig(config); print("  saved")
end

local function review(config)
  local b = config.bindings
  print("-- bindings --")
  for _, k in ipairs({ "gimbalPitchIdx","gimbalRollIdx","gimbalScale","signPitch","signRoll",
    "signVelFront","signVelRear","signVelMedial","signHeading","headingScale","signYawRate",
    "yawBaseline","heightOffset","onGroundThreshold","baroThrusterOffset" }) do
    print(("  %-18s %s"):format(k, tostring(b[k])))
  end
  saveConfig(config); print("written to " .. CONFIG_PATH)
end

function M.run()
  local shim = require("fcs.io.shim")
  local config = loadConfig()
  while true do
    print("\n== EH2 CALIBRATE == 1 attitude 2 lateral 3 surge 4 heading 5 ground 6 constants 7 review q quit")
    local ch = read()
    if ch == "1" then stepAttitude(shim, config)
    elseif ch == "2" then stepLateral(shim, config)
    elseif ch == "3" then stepSurge(shim, config)
    elseif ch == "4" then stepHeading(shim, config)
    elseif ch == "5" then stepGround(shim, config)
    elseif ch == "6" then stepConstants(config)
    elseif ch == "7" then review(config)
    elseif ch == "q" then return end
  end
end
```

- [ ] **Step 2: Run to verify nothing breaks**

Run: `bash tests/run_headless.sh`
Expected: OK — the file still parses/loads (the `require("tools.calibrate")` in `tests.test_calibrate` succeeds) and all pure-helper tests pass. `run()` is defined but never called in tests.

- [ ] **Step 3: Commit**

```bash
git add tools/calibrate.lua
git commit -m "feat(cal): interactive calibration shell — guided per-axis steps"
```

- [ ] **Step 4: In-game manual checklist (record results, do not automate)**
  - Install (Task 8), launch `calibrate`.
  - `1 attitude`: nose-up should classify pitch with a positive sign in the craft's native unit; right-wing-down should classify roll. Confirm the reported idx/unit look sane.
  - `2 lateral`: rightward shove then nose-right yaw; both statuses `ok`.
  - `3 surge`: forward shove; positive sign.
  - `4 heading`: 90 deg right; unit/sign sane.
  - `5 ground`: on the ground; heightOffset makes altitude read ~0 afterwards (verify with the probe's sensor read).
  - `6 constants`: enter measured yawBaseline + baroThrusterOffset.
  - `7 review`: whole table looks right; file written.

---

### Task 8: Installer wiring + `/calibrate` launcher

**Files:**
- Modify: `tools/install_probe.lua:9-15` (FILES list) and `:41-45` (launcher writing)

**Interfaces:**
- Consumes: nothing new.
- Produces: `wget run .../install_probe.lua` also fetches `tools/calibrate.lua` + `fcs/io/calibration.lua` and writes a `/calibrate` launcher alongside `/probe`.

- [ ] **Step 1: Add the two files to the fetch list** — in `tools/install_probe.lua`, extend `FILES`:

```lua
local FILES = {
  "tools/probe.lua",
  "tools/calibrate.lua",
  "fcs/io/shim.lua",
  "fcs/io/backend.lua",
  "fcs/io/hwconfig.lua",
  "fcs/io/calibration.lua",
  "fcs/frame.lua",
}
```

- [ ] **Step 2: Write the `/calibrate` launcher** — in `tools/install_probe.lua`, after the block that writes the `probe` launcher (the `lf` open/write/close), add:

```lua
local CAL_LAUNCHER = 'package.path = "/?.lua;/?/init.lua;" .. package.path\n'
                  .. 'require("tools.calibrate").run()\n'
local cf = fs.open("calibrate", "w")
cf.write(CAL_LAUNCHER)
cf.close()
```

And update the closing print block to mention both:

```lua
print("")
print("Installed. Start the bring-up probe with:")
print("  probe")
print("Run guided sensor calibration with:")
print("  calibrate")
```

- [ ] **Step 3: Verify the installer is well-formed** — this file uses CC globals (`http`, `fs`) and is not headless-run, so confirm it loads without syntax error:

Run: `bash tests/run_headless.sh`
Expected: OK — unaffected (installer isn't in the suite); this step is a guard that you didn't break the repo. Eyeball `tools/install_probe.lua` for the two edits.

- [ ] **Step 4: Commit**

```bash
git add tools/install_probe.lua
git commit -m "feat(cal): installer fetches calibrate + calibration, writes /calibrate launcher"
```

- [ ] **Step 5: Tag the completed plan**

```bash
git tag -a plan7-calibration -m "Plan 7: guided sensor calibration — core + tool + installer"
```

---

## Self-Review

**Spec coverage:**
- §2 targets — gimbal idx/sign/unit (Task 2), velFront/Rear signs (Task 3), velMedial sign (scalar, Task 1 + surge step Task 7), heading sign+scale (Task 4), yawRate sign (Task 3), heightOffset + onGroundThreshold (Task 4), yawBaseline + baroThrusterOffset (typed, Task 6/7). ✓
- §3 convention — encoded verbatim in Global Constraints and the step prompts. ✓
- §4 robustness rules — dominant channel (Task 2), gate (Task 1), common/differential (Task 3), peak-vs-steady (Task 7 stream/peak helpers). ✓
- §5 procedure/menu — Task 7 (menu is `1 attitude 2 lateral 3 surge 4 heading 5 ground 6 constants 7 review`; the optional "verify thrusters" step from spec §5 is omitted here — see note). ✓ (with note)
- §6 persistence/backend/delivery/testing — Task 5 (backend+defaults), Task 7 (persistence), Task 8 (delivery), Tasks 1–4/6 (tests). ✓

**Scope note:** the spec's optional step-7 "verify thrusters" (fire each role, watch the corner) is deliberately deferred out of this plan — it is not a gate, the probe already fires thrusters, and it belongs with the future test-stand work. Not a coverage gap for calibration itself.

**Placeholder scan:** no TBD/TODO; every code step has literal content. ✓

**Type consistency:** binding key `gimbalScale` used consistently (Tasks 5, 6); `classifyGimbalAxis` returns `{idx,sign,unit,scale,...}` consumed by `applyGimbal` (Task 6) and asserted in Task 2; `classifyLateralPair` returns `{signFront,signRear,signYawRate,...}` consumed by `applyLateral`; `detectHeadingScale` returns `{sign,scale,...}` consumed by `applyHeading`. Backend fallbacks match default keys in hwconfig. ✓
