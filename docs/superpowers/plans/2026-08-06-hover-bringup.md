# Hover Bring-Up Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A keypress-triggered in-game tool that flies an automated climb → hold → land profile on the real craft and logs every control cycle to a file for analysis.

**Architecture:** A pure, headless-tested profile state machine (`fcs/bringup/profile.lua`) and a pure instrumentation/summary module (`fcs/bringup/instrument.lua`); a canonical tuning table (`fcs/tuning.lua`); two small backward-compatible enhancements to the existing `Loop`; and an in-game shell (`tools/hover_test.lua`) that wires the real backend into the `Loop`, drives the profile, and writes the log.

**Tech Stack:** CC:Tweaked Lua 5.1, CraftOS-PC headless test harness, existing `tests/framework.lua`.

## Global Constraints

- **Lua 5.1** (CC:Tweaked runtime) — no goto, no integer division, no `#` on nil.
- **Wrapped peripherals take NO `self`** — `p.getAngles()`, never `p:getAngles()`. (Only relevant in the shell; the backend already handles all peripheral IO.)
- **Prints are ASCII-only** (real CC font). No unicode.
- **Tests run via** `bash tests/run_headless.sh` (runs ALL suites; no single-test runner). New suites MUST be added to the `suites` table in that script's `startup.lua` heredoc.
- **Test API is only** `t.test/t.eq/t.near/t.truthy`. No external dependencies.
- **`Loop` changes MUST be backward-compatible** — existing callers use `Loop:cycle(dt)` with no `m` and ignore the return value; those must keep working (the whole `tests/test_integration.lua` suite depends on it).
- **Known-good tuning (verbatim, from `tests/test_integration.lua`):** `hoverDuty=0.66`; `alt {kp=0.04,ki=0.02,kd=0.30,tauD=0.2,iMax=0.3,iMin=-0.3}`; `pitch/roll {kp=0.3,ki=0,kd=0.4,tauD=0.2}`; `yaw {kp=0.8,ki=0,kd=1.4}`; `sway {kp=0.5,ki=0,kd=0.5}`; `surge {kp=0.3,ki=0,kd=0.5}`; pwm `period=0.3`.

## File Structure

- Create `fcs/tuning.lua` — canonical tuning table (Task 1).
- Create `fcs/bringup/profile.lua` — pure climb/hold/land state machine (Task 2).
- Create `fcs/bringup/instrument.lua` — pure CSV header/row + incremental Summary (Task 3).
- Modify `fcs/runtime/loop.lua` — optional pre-read `m` + diagnostics return (Task 4).
- Create `tools/hover_test.lua` — in-game shell (Task 5).
- Create `tools/install_hovertest.lua` — installer + `/hovertest` launcher (Task 6).
- Create tests `tests/test_tuning.lua`, `tests/test_profile.lua`, `tests/test_instrument.lua`, `tests/test_loop.lua`, `tests/test_hover_test.lua`; register each in `tests/run_headless.sh`.

---

### Task 1: `fcs/tuning.lua` — canonical tuning table

**Files:**
- Create: `fcs/tuning.lua`
- Test: `tests/test_tuning.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Produces: a module returning a table with `gains` (`hoverDuty`, `alt`, `pitch`, `roll`, `yaw`, `sway`, `surge`), `pwmPeriod`, `caps`, `osc`, `dtMax`, `profile` (`climbHeight`, `climbRate`, `holdTime`, `descendRate`, `landEps`, `watchdog`, `overshootMargin`).

- [ ] **Step 1: Write the failing test** — create `tests/test_tuning.lua`:

```lua
local t = require("tests.framework")
local T = require("fcs.tuning")

t.test("tuning exposes the known-good gains", function()
  t.near(T.gains.hoverDuty, 0.66, 1e-9)
  t.near(T.gains.alt.kd, 0.30, 1e-9)
  t.near(T.gains.yaw.kd, 1.4, 1e-9)
end)
t.test("tuning exposes actuator + safety params", function()
  t.near(T.pwmPeriod, 0.3, 1e-9)
  t.near(T.caps.pitch, 0.2, 1e-9)
  t.eq(T.osc.minChanges, 6)
  t.near(T.dtMax, 0.5, 1e-9)
end)
t.test("tuning exposes the flight profile params", function()
  t.near(T.profile.climbHeight, 5, 1e-9)
  t.near(T.profile.holdTime, 10, 1e-9)
  t.near(T.profile.descendRate, 0.7, 1e-9)
end)
```

- [ ] **Step 2: Register the suite** — in `tests/run_headless.sh`, append `"tests.test_tuning"` to the `suites` table in the `startup.lua` heredoc (after the last existing entry, e.g. `"tests.test_calibrate"`).

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — `SUITE LOAD FAILURES` for `tests.test_tuning` (module not found).

- [ ] **Step 4: Write the implementation** — create `fcs/tuning.lua`:

```lua
-- Canonical FCS tuning — the single source of truth for the hover bring-up runner.
-- Known-good sim gains (mirrored from tests/test_integration.lua) + actuator/safety/profile
-- params. RETUNE HERE between flights. hoverDuty=0.66 is the SIM value; if the real craft's
-- thrust-to-weight differs a lot the altitude integrator (+/-0.3 authority) may saturate and
-- it won't hold -- adjust hoverDuty and re-fly.
return {
  gains = {
    hoverDuty = 0.66,
    alt   = { kp = 0.04, ki = 0.02, kd = 0.30, tauD = 0.2, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    roll  = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    yaw   = { kp = 0.8, ki = 0, kd = 1.4 },
    sway  = { kp = 0.5, ki = 0, kd = 0.5 },
    surge = { kp = 0.3, ki = 0, kd = 0.5 },
  },
  pwmPeriod = 0.3,
  caps = { pitch = 0.2, roll = 0.2, yaw = 0.5, sway = 0.5, surge = 0.5 },  -- attitude/steering only; heave unclamped
  osc = { window = 1.0, minChanges = 6 },
  dtMax = 0.5,
  profile = { climbHeight = 5, climbRate = 1.0, holdTime = 10, descendRate = 0.7,
              landEps = 0.4, watchdog = 30, overshootMargin = 2 },
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — all suites pass, including `tests.test_tuning`.

- [ ] **Step 6: Commit**

```bash
git add fcs/tuning.lua tests/test_tuning.lua tests/run_headless.sh
git commit -m "feat(tuning): canonical FCS tuning table for the hover bring-up runner"
```

---

### Task 2: `fcs/bringup/profile.lua` — climb/hold/land state machine

**Files:**
- Create: `fcs/bringup/profile.lua`
- Test: `tests/test_profile.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Produces:
  - `Profile.new(cfg)` — cfg fields: `baseAlt`, `climbHeight`, `climbRate`, `holdTime`, `descendRate`, `landEps`, `watchdog`, `overshootMargin` (each defaulted).
  - `Profile:begin()` — IDLE → CLIMB.
  - `Profile:abort()` — force DESCEND unless LANDED.
  - `Profile:update(dt, alt, onGround) -> { phase, targetAlt, active, done }`. `phase` ∈ `"IDLE"|"CLIMB"|"HOLD"|"DESCEND"|"LANDED"`; `active` = phase ∈ {CLIMB,HOLD,DESCEND}; `done` = phase == LANDED.

- [ ] **Step 1: Write the failing test** — create `tests/test_profile.lua`:

```lua
local t = require("tests.framework")
local Profile = require("fcs.bringup.profile")
local function P(over)
  local c = { baseAlt=0, climbHeight=5, climbRate=1, holdTime=2, descendRate=1,
              landEps=0.4, watchdog=100, overshootMargin=2 }
  if over then for k,v in pairs(over) do c[k]=v end end
  return Profile.new(c)
end

t.test("IDLE holds baseAlt and is inactive", function()
  local r = P():update(1, 0, false)
  t.eq(r.phase,"IDLE"); t.near(r.targetAlt,0,1e-9); t.eq(r.active,false); t.eq(r.done,false)
end)
t.test("begin enters CLIMB and ramps the setpoint at climbRate", function()
  local p = P(); p:begin(); local r = p:update(1, 0, false)
  t.eq(r.phase,"CLIMB"); t.near(r.targetAlt,1,1e-9); t.eq(r.active,true)
end)
t.test("CLIMB caps at top then transitions to HOLD", function()
  local p = P(); p:begin(); p:update(3, 1, false)
  local r = p:update(3, 3, false)     -- target 3 -> capped 5, reaches top -> HOLD
  t.near(r.targetAlt,5,1e-9); t.eq(r.phase,"HOLD")
end)
t.test("HOLD stays at top for holdTime then DESCEND", function()
  local p = P(); p:begin(); p:update(5, 5, false)   -- into HOLD
  t.eq(p.phase,"HOLD")
  local r = p:update(2, 5, false)                    -- held 2 >= 2 -> DESCEND
  t.eq(r.phase,"DESCEND")
end)
t.test("DESCEND lands on onGround", function()
  local p = P(); p:begin(); p:update(5,5,false); p:update(2,5,false)
  local r = p:update(1, 4, true)
  t.eq(r.phase,"LANDED"); t.eq(r.done,true); t.eq(r.active,false)
end)
t.test("DESCEND lands when altitude within landEps of baseAlt", function()
  local p = P(); p:begin(); p:update(5,5,false); p:update(2,5,false)
  local r = p:update(1, 0.3, false)   -- 0.3 <= 0 + 0.4
  t.eq(r.phase,"LANDED"); t.eq(r.done,true)
end)
t.test("abort from CLIMB forces DESCEND", function()
  local p = P(); p:begin(); p:update(1,1,false); p:abort()
  t.eq(p:update(0.1, 1, false).phase, "DESCEND")
end)
t.test("watchdog forces DESCEND after timeout", function()
  local p = P({watchdog=3}); p:begin(); p:update(2, 2, false)
  t.eq(p:update(2, 4, false).phase, "DESCEND")   -- elapsed 4 >= 3
end)
t.test("overshoot forces DESCEND", function()
  local p = P(); p:begin()
  t.eq(p:update(1, 8, false).phase, "DESCEND")   -- alt 8 > top 5 + margin 2
end)
t.test("LANDED stays landed and inactive", function()
  local p = P(); p:begin(); p:update(5,5,false); p:update(2,5,false); p:update(1,0,true)
  local r = p:update(1, 0, true)
  t.eq(r.phase,"LANDED"); t.eq(r.active,false); t.eq(r.done,true)
end)
```

- [ ] **Step 2: Register the suite** — in `tests/run_headless.sh`, append `"tests.test_profile"` to the `suites` table.

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — `SUITE LOAD FAILURES` for `tests.test_profile`.

- [ ] **Step 4: Write the implementation** — create `fcs/bringup/profile.lua`:

```lua
-- Pure climb/hold/land state machine for the hover bring-up runner. No CC dependencies.
local Profile = {}
Profile.__index = Profile

function Profile.new(cfg)
  cfg = cfg or {}
  local self = setmetatable({}, Profile)
  self.baseAlt = cfg.baseAlt or 0
  self.climbHeight = cfg.climbHeight or 5
  self.climbRate = cfg.climbRate or 1.0
  self.holdTime = cfg.holdTime or 10
  self.descendRate = cfg.descendRate or 0.7
  self.landEps = cfg.landEps or 0.4
  self.watchdog = cfg.watchdog or 30
  self.overshootMargin = cfg.overshootMargin or 2
  self.top = self.baseAlt + self.climbHeight
  self.phase = "IDLE"
  self.target = self.baseAlt
  self.elapsed = 0
  self.held = 0
  return self
end

function Profile:begin()
  if self.phase == "IDLE" then self.phase = "CLIMB"; self.elapsed = 0 end
end

function Profile:abort()
  if self.phase ~= "LANDED" then self.phase = "DESCEND" end
end

function Profile:update(dt, alt, onGround)
  dt = (dt and dt > 0) and dt or 0
  if self.phase ~= "IDLE" and self.phase ~= "LANDED" then
    self.elapsed = self.elapsed + dt
    if self.elapsed >= self.watchdog then self.phase = "DESCEND" end
    if alt and alt > self.top + self.overshootMargin then self.phase = "DESCEND" end
  end
  if self.phase == "CLIMB" then
    self.target = math.min(self.top, self.target + self.climbRate * dt)
    if self.target >= self.top then self.phase = "HOLD"; self.held = 0 end
  elseif self.phase == "HOLD" then
    self.target = self.top
    self.held = self.held + dt
    if self.held >= self.holdTime then self.phase = "DESCEND" end
  elseif self.phase == "DESCEND" then
    self.target = math.max(self.baseAlt, self.target - self.descendRate * dt)
    if (onGround == true) or (alt and alt <= self.baseAlt + self.landEps) then
      self.phase = "LANDED"
    end
  else -- IDLE or LANDED
    self.target = self.baseAlt
  end
  local active = self.phase == "CLIMB" or self.phase == "HOLD" or self.phase == "DESCEND"
  return { phase = self.phase, targetAlt = self.target, active = active,
           done = self.phase == "LANDED" }
end

return Profile
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — all suites pass.

- [ ] **Step 6: Commit**

```bash
git add fcs/bringup/profile.lua tests/test_profile.lua tests/run_headless.sh
git commit -m "feat(bringup): climb/hold/land profile state machine with safety cutoffs"
```

---

### Task 3: `fcs/bringup/instrument.lua` — CSV rows + incremental summary

**Files:**
- Create: `fcs/bringup/instrument.lua`
- Test: `tests/test_instrument.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: `fcs.frame` (`LIFT`, `LATERAL`, `MAIN`, `FRONTAL` id lists).
- Produces:
  - `M.header() -> string` (CSV header).
  - `M.formatRow(sample) -> string` (CSV line; derives `dt_ms`/`hz` from `sample.dt`).
  - `M.Summary.new()`, `summary:add(sample)`, `summary:finalize() -> metrics`.
  - `M.formatSummary(metrics) -> string`.
- A **sample** is a table: `{ t, dt, phase, mode, sp_alt, alt, vSpeed, pitch, roll, heading, yawRate, swayVel, surgeVel, swayPos, surgePos, onGround, heave, dPitch, dRoll, dYaw, dSway, dSurge, duties={<role>=<0..1>} }`.

- [ ] **Step 1: Write the failing test** — create `tests/test_instrument.lua`:

```lua
local t = require("tests.framework")
local I = require("fcs.bringup.instrument")

t.test("header and formatRow agree on column count", function()
  local ncols = select(2, I.header():gsub(",", ",")) + 1
  local row = I.formatRow({ t=0, dt=0.1, phase="CLIMB", mode="NORMAL", onGround=false, duties={} })
  local nrow = select(2, row:gsub(",", ",")) + 1
  t.eq(nrow, ncols)
end)
t.test("Summary computes bob amplitude from HOLD samples", function()
  local s = I.Summary.new()
  s:add({ t=0,   dt=0.1, phase="HOLD", alt=5.0, sp_alt=5, heading=0 })
  s:add({ t=0.1, dt=0.1, phase="HOLD", alt=5.3, sp_alt=5, heading=0 })
  s:add({ t=0.2, dt=0.1, phase="HOLD", alt=4.8, sp_alt=5, heading=0 })
  t.near(s:finalize().bobAmplitude, 0.5, 1e-9)
end)
t.test("Summary tracks per-phase alt error and average Hz", function()
  local s = I.Summary.new()
  s:add({ t=0,   dt=0.2, phase="CLIMB", alt=1.0, sp_alt=1.5, heading=0 })
  s:add({ t=0.2, dt=0.2, phase="CLIMB", alt=2.0, sp_alt=2.0, heading=0 })
  local m = s:finalize()
  t.near(m.errClimb.mean, 0.25, 1e-9); t.near(m.errClimb.max, 0.5, 1e-9)
  t.near(m.hzAvg, 5, 1e-9)
end)
t.test("Summary flags DAMPED and captures touchdown + drift + heading drift", function()
  local s = I.Summary.new()
  s:add({ t=0,   dt=0.1, phase="DESCEND", alt=1,   sp_alt=1,   vSpeed=-0.5, mode="NORMAL", swayPos=0,   surgePos=0,    heading=0 })
  s:add({ t=0.1, dt=0.1, phase="DESCEND", alt=0.5, sp_alt=0.5, vSpeed=-0.3, mode="DAMPED", swayPos=0.4, surgePos=-0.2, heading=0.1 })
  s:add({ t=0.2, dt=0.1, phase="LANDED",  alt=0,   sp_alt=0,   vSpeed=-0.1, mode="NORMAL", swayPos=0.2, surgePos=0,    heading=0.05 })
  local m = s:finalize()
  t.eq(m.damped, true)
  t.near(m.touchdownV, -0.1, 1e-9)
  t.near(m.swayRange, 0.4, 1e-9)
  t.near(m.surgeRange, 0.2, 1e-9)
  t.near(m.headingDrift, 0.1, 1e-9)
end)
t.test("formatSummary produces readable key: value lines", function()
  local s = I.Summary.new(); s:add({ t=0, dt=0.1, phase="HOLD", alt=5, sp_alt=5, heading=0 })
  local out = I.formatSummary(s:finalize())
  t.truthy(out:find("hold_bob_amplitude_blocks:"))
  t.truthy(out:find("loop_hz:"))
end)
```

- [ ] **Step 2: Register the suite** — append `"tests.test_instrument"` to the `suites` table in `tests/run_headless.sh`.

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — `SUITE LOAD FAILURES` for `tests.test_instrument`.

- [ ] **Step 4: Write the implementation** — create `fcs/bringup/instrument.lua`:

```lua
-- Pure instrumentation for the hover bring-up runner: CSV rows + an incremental summary
-- (no in-memory row hoarding). No CC dependencies.
local frame = require("fcs.frame")
local M = {}

local DUTY_IDS = {}
for _, id in ipairs(frame.LIFT)    do DUTY_IDS[#DUTY_IDS+1] = id end
for _, id in ipairs(frame.LATERAL) do DUTY_IDS[#DUTY_IDS+1] = id end
for _, id in ipairs(frame.MAIN)    do DUTY_IDS[#DUTY_IDS+1] = id end
for _, id in ipairs(frame.FRONTAL) do DUTY_IDS[#DUTY_IDS+1] = id end

local SCALAR_COLS = { "t","dt_ms","hz","phase","mode","sp_alt","alt","vSpeed","pitch","roll",
  "heading","yawRate","swayVel","surgeVel","swayPos","surgePos","onGround","heave",
  "dPitch","dRoll","dYaw","dSway","dSurge" }

function M.header()
  local cols = {}
  for _, c in ipairs(SCALAR_COLS) do cols[#cols+1] = c end
  for _, id in ipairs(DUTY_IDS) do cols[#cols+1] = id end
  return table.concat(cols, ",")
end

local function num(v) return string.format("%.4f", v or 0) end

function M.formatRow(s)
  local dt = s.dt or 0
  local vals = {
    num(s.t), num(dt*1000), num(dt > 0 and 1/dt or 0), tostring(s.phase or ""),
    tostring(s.mode or ""), num(s.sp_alt), num(s.alt), num(s.vSpeed), num(s.pitch),
    num(s.roll), num(s.heading), num(s.yawRate), num(s.swayVel), num(s.surgeVel),
    num(s.swayPos), num(s.surgePos), s.onGround and "1" or "0", num(s.heave),
    num(s.dPitch), num(s.dRoll), num(s.dYaw), num(s.dSway), num(s.dSurge),
  }
  local d = s.duties or {}
  for _, id in ipairs(DUTY_IDS) do vals[#vals+1] = num(d[id]) end
  return table.concat(vals, ",")
end

local Summary = {}
Summary.__index = Summary
M.Summary = Summary

function Summary.new()
  return setmetatable({
    n = 0, tFirst = nil, tLast = 0,
    hzMin = math.huge, hzMax = 0, hzSum = 0, hzN = 0,
    heading0 = nil, headingDrift = 0,
    swayMin = math.huge, swayMax = -math.huge, surgeMin = math.huge, surgeMax = -math.huge,
    maxPitch = 0, maxRoll = 0, peakClimbV = 0, peakDescentV = 0,
    holdAltMin = math.huge, holdAltMax = -math.huge,
    perr = { CLIMB={sum=0,max=0,n=0}, HOLD={sum=0,max=0,n=0}, DESCEND={sum=0,max=0,n=0} },
    damped = false, touchdownV = nil, lastPhase = nil,
  }, Summary)
end

function Summary:add(s)
  self.n = self.n + 1
  if self.tFirst == nil then self.tFirst = s.t or 0 end
  self.tLast = s.t or self.tLast
  local dt = s.dt or 0
  if dt > 0 then
    local hz = 1/dt
    if hz < self.hzMin then self.hzMin = hz end
    if hz > self.hzMax then self.hzMax = hz end
    self.hzSum = self.hzSum + hz; self.hzN = self.hzN + 1
  end
  if self.heading0 == nil then self.heading0 = s.heading or 0 end
  local hd = math.abs((s.heading or 0) - self.heading0)
  if hd > self.headingDrift then self.headingDrift = hd end
  local sp, su = s.swayPos or 0, s.surgePos or 0
  if sp < self.swayMin then self.swayMin = sp end
  if sp > self.swayMax then self.swayMax = sp end
  if su < self.surgeMin then self.surgeMin = su end
  if su > self.surgeMax then self.surgeMax = su end
  if math.abs(s.pitch or 0) > self.maxPitch then self.maxPitch = math.abs(s.pitch or 0) end
  if math.abs(s.roll or 0) > self.maxRoll then self.maxRoll = math.abs(s.roll or 0) end
  local v = s.vSpeed or 0
  if v > self.peakClimbV then self.peakClimbV = v end
  if v < self.peakDescentV then self.peakDescentV = v end
  if s.mode == "DAMPED" then self.damped = true end
  if s.phase == "HOLD" then
    local a = s.alt or 0
    if a < self.holdAltMin then self.holdAltMin = a end
    if a > self.holdAltMax then self.holdAltMax = a end
  end
  local pe = self.perr[s.phase]
  if pe then
    local e = math.abs((s.alt or 0) - (s.sp_alt or 0))
    pe.sum = pe.sum + e; pe.n = pe.n + 1
    if e > pe.max then pe.max = e end
  end
  if s.phase == "LANDED" and self.lastPhase ~= "LANDED" then self.touchdownV = v end
  self.lastPhase = s.phase
end

local function mean(sum, n) return n > 0 and (sum / n) or 0 end

function Summary:finalize()
  local dur = (self.tFirst ~= nil) and (self.tLast - self.tFirst) or 0
  local bob = (self.holdAltMax >= self.holdAltMin) and (self.holdAltMax - self.holdAltMin) or 0
  local function perrOf(k) local p = self.perr[k]; return { mean = mean(p.sum, p.n), max = p.max } end
  return {
    samples = self.n, duration = dur,
    hzMin = self.hzMin == math.huge and 0 or self.hzMin, hzMax = self.hzMax,
    hzAvg = mean(self.hzSum, self.hzN),
    bobAmplitude = bob, peakClimbV = self.peakClimbV, peakDescentV = self.peakDescentV,
    maxPitch = self.maxPitch, maxRoll = self.maxRoll,
    swayRange = (self.swayMax >= self.swayMin) and (self.swayMax - self.swayMin) or 0,
    surgeRange = (self.surgeMax >= self.surgeMin) and (self.surgeMax - self.surgeMin) or 0,
    headingDrift = self.headingDrift, touchdownV = self.touchdownV or 0, damped = self.damped,
    errClimb = perrOf("CLIMB"), errHold = perrOf("HOLD"), errDescend = perrOf("DESCEND"),
  }
end

function M.formatSummary(m)
  local lines = {
    "# EasyHover 2 hover bring-up log",
    "samples: " .. m.samples,
    string.format("duration_s: %.2f", m.duration),
    string.format("loop_hz: min %.2f avg %.2f max %.2f", m.hzMin, m.hzAvg, m.hzMax),
    string.format("hold_bob_amplitude_blocks: %.3f", m.bobAmplitude),
    string.format("peak_climb_vSpeed: %.3f", m.peakClimbV),
    string.format("peak_descent_vSpeed: %.3f", m.peakDescentV),
    string.format("touchdown_vSpeed: %.3f", m.touchdownV),
    string.format("max_pitch: %.4f  max_roll: %.4f", m.maxPitch, m.maxRoll),
    string.format("horizontal_drift_blocks: sway %.3f  surge %.3f", m.swayRange, m.surgeRange),
    string.format("heading_drift: %.4f", m.headingDrift),
    string.format("alt_err_climb: mean %.3f max %.3f", m.errClimb.mean, m.errClimb.max),
    string.format("alt_err_hold: mean %.3f max %.3f", m.errHold.mean, m.errHold.max),
    string.format("alt_err_descend: mean %.3f max %.3f", m.errDescend.mean, m.errDescend.max),
    "damped_tripped: " .. (m.damped and "YES" or "no"),
  }
  return table.concat(lines, "\n")
end

return M
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — all suites pass.

- [ ] **Step 6: Commit**

```bash
git add fcs/bringup/instrument.lua tests/test_instrument.lua tests/run_headless.sh
git commit -m "feat(bringup): CSV instrumentation + incremental flight summary"
```

---

### Task 4: `fcs/runtime/loop.lua` — optional pre-read `m` + diagnostics return

**Files:**
- Modify: `fcs/runtime/loop.lua` (`cycle`)
- Test: `tests/test_loop.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Produces: `Loop:cycle(dt, m)` — if `m` is passed, it is used instead of `self.backend:sensors()`; returns `{ mode, m, demands, duties }` (`demands`/`duties` are `nil` when disarmed).
- Consumes (test only): `fcs.mixer.level_flight`.

- [ ] **Step 1: Write the failing test** — create `tests/test_loop.lua`:

```lua
local t = require("tests.framework")
local Loop = require("fcs.runtime.loop")
local Mixer = require("fcs.mixer.level_flight")

local function fakeBackend()
  local b = { reads = 0, thrusts = {} }
  b.sensors = function()
    b.reads = b.reads + 1
    return { altitude=0, vSpeed=0, pitch=0, roll=0, heading=0, yawRate=0,
             swayVel=0, surgeVel=0, swayPos=0, surgePos=0, onGround=false }
  end
  b.setThruster = function(id, on) b.thrusts[id] = on end
  return b
end
local function fakeScheme()
  return { reset = function() end,
           update = function() return { heave=0.5, pitch=0, roll=0, yaw=0, sway=0, surge=0 } end }
end
local function fakePwm() return { apply = function() end, state = function() return false end } end
local function build()
  local b = fakeBackend()
  local loop = Loop.new({ scheme = fakeScheme(), mixer = Mixer.new(), pwm = fakePwm(),
    backend = b, dtMax = 0.5 })
  return loop, b
end
local M0 = { altitude=0, vSpeed=0, pitch=0, roll=0, heading=0, yawRate=0,
             swayVel=0, surgeVel=0, swayPos=0, surgePos=0, onGround=false }

t.test("cycle(dt, m) uses the provided measurement (no internal sensor read)", function()
  local loop, b = build(); loop:arm(true)
  loop:cycle(0.1, M0)
  t.eq(b.reads, 0)
end)
t.test("cycle(dt) with no m reads internally (backward compat)", function()
  local loop, b = build(); loop:arm(true)
  loop:cycle(0.1)
  t.eq(b.reads, 1)
end)
t.test("cycle returns diagnostics when armed", function()
  local loop = build(); loop:arm(true)
  local d = loop:cycle(0.1, M0)
  t.eq(d.mode, "NORMAL"); t.truthy(d.demands ~= nil); t.truthy(d.duties.FL ~= nil)
end)
t.test("cycle returns nil demands/duties when disarmed", function()
  local loop = build()
  local d = loop:cycle(0.1, M0)
  t.eq(d.demands, nil); t.eq(d.duties, nil)
end)
```

- [ ] **Step 2: Register the suite** — append `"tests.test_loop"` to the `suites` table in `tests/run_headless.sh`.

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — the `cycle(dt, m)` test finds `b.reads == 1` (current code always calls `backend:sensors()`), and the diagnostics tests fail because `cycle` returns `nil`.

- [ ] **Step 4: Write the implementation** — edit `fcs/runtime/loop.lua`. Change the signature line:

```lua
function Loop:cycle(dt)
```
to:
```lua
function Loop:cycle(dt, m)
```

Change the sensor-read line:
```lua
  local m = self.backend:sensors()
```
to:
```lua
  m = m or self.backend:sensors()
```

Change the disarmed early return (the bare `return` after `self:apply(zeros, dt)`):
```lua
    self:apply(zeros, dt)
    return
```
to:
```lua
    self:apply(zeros, dt)
    return { mode = self.mode, m = m, demands = nil, duties = nil }
```

Change the end of the armed path — after the final `self:apply(duties, dt)` line, add a return:
```lua
  local duties = self.mixer:mix(demands)
  self:apply(duties, dt)
  return { mode = self.mode, m = m, demands = demands, duties = duties }
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — new `test_loop` cases pass; `tests.test_integration` (which calls `cycle(dt)` and ignores the return) still passes.

- [ ] **Step 6: Commit**

```bash
git add fcs/runtime/loop.lua tests/test_loop.lua tests/run_headless.sh
git commit -m "feat(runtime): Loop:cycle accepts a pre-read measurement and returns diagnostics"
```

---

### Task 5: `tools/hover_test.lua` — in-game shell

**Files:**
- Create: `tools/hover_test.lua`
- Test: `tests/test_hover_test.lua` (parse-load smoke only)
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: `fcs.io.hwconfig`, `fcs.tuning`, `fcs.io.backend`, `fcs.io.shim`, `fcs.schemes.level_flight`, `fcs.mixer.level_flight`, `fcs.actuate.pwm`, `fcs.actuate.sigma_delta`, `fcs.runtime.loop` (`cycle(dt, m) -> {mode,m,demands,duties}`), `fcs.bringup.profile` (`Profile.new/:begin/:abort/:update`), `fcs.bringup.instrument` (`header/formatRow/Summary/formatSummary`).
- Produces: module `{ run = <function> }`. `run()` is in-game only (uses CC globals `fs`, `os`, `keys`, `sleep`, `shell`, `textutils`, `print`, `os.pullEvent`).

- [ ] **Step 1: Write the failing test** — create `tests/test_hover_test.lua`:

```lua
local t = require("tests.framework")
local H = require("tools.hover_test")
t.test("hover_test module loads and exposes run()", function()
  t.eq(type(H.run), "function")
end)
```

- [ ] **Step 2: Register the suite** — append `"tests.test_hover_test"` to the `suites` table in `tests/run_headless.sh`.

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — `SUITE LOAD FAILURES` for `tests.test_hover_test`.

- [ ] **Step 4: Write the implementation** — create `tools/hover_test.lua`:

```lua
-- EasyHover 2 -- hover bring-up test. IN-GAME ONLY (real peripherals + CC globals).
-- Flies an automated climb->hold->land profile, logs every cycle to /eh2_hover_log.csv.
-- Controls: SPACE launch, Q abort-to-land. Physical fuel-pull = hard kill.
-- Wrapped peripherals take NO self (all peripheral IO is inside fcs.io.backend).
local hwconfig = require("fcs.io.hwconfig")
local tuning   = require("fcs.tuning")
local Backend  = require("fcs.io.backend")
local Scheme   = require("fcs.schemes.level_flight")
local Mixer    = require("fcs.mixer.level_flight")
local Pwm      = require("fcs.actuate.pwm")
local SD       = require("fcs.actuate.sigma_delta")
local Loop     = require("fcs.runtime.loop")
local Profile  = require("fcs.bringup.profile")
local Inst     = require("fcs.bringup.instrument")

local CONFIG_PATH = "/eh2_hw_config.tbl"
local LOG_PATH  = "/eh2_hover_log.csv"
local PART_PATH = "/eh2_hover_log.csv.part"

local function loadConfig()
  local saved
  if fs.exists(CONFIG_PATH) then
    local f = fs.open(CONFIG_PATH, "r"); saved = textutils.unserialise(f.readAll() or ""); f.close()
  end
  return hwconfig.merge(saved or {}, hwconfig.defaults())
end

local function buildLoop(backend)
  local g = tuning.gains
  local scheme = Scheme.new({ hoverDuty = g.hoverDuty, alt = g.alt, pitch = g.pitch,
    roll = g.roll, yaw = g.yaw, sway = g.sway, surge = g.surge })
  return Loop.new({ scheme = scheme, mixer = Mixer.new(),
    pwm = Pwm.new({ period = tuning.pwmPeriod, backend = backend }),
    sd = SD.new({ backend = backend }),
    backend = backend, dtMax = tuning.dtMax, caps = tuning.caps, osc = tuning.osc })
end

local function baseline(backend)
  local n, altS, hdgS, sway, surge = 5, 0, 0, 0, 0
  for _ = 1, n do
    local s = backend:sensors()
    altS = altS + s.altitude; hdgS = hdgS + s.heading
    sway, surge = s.swayPos, s.surgePos
    sleep(0.1)
  end
  return altS / n, hdgS / n, sway, surge
end

local function killThrusters(backend)
  local groups = { backend:liftIds(), backend:lateralIds(), backend:mainIds(), backend:frontalIds() }
  for _, ids in ipairs(groups) do
    for _, id in ipairs(ids) do pcall(function() backend:setThruster(id, false) end) end
  end
end

local function flight(backend, loop, profile, summary, heading0, swayPos0, surgePos0, part)
  local t0 = os.epoch("utc")
  local lastT = t0
  local timer = os.startTimer(0)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      local now = os.epoch("utc")
      local dt = (now - lastT) / 1000
      lastT = now
      local m = backend:sensors()
      local pr = profile:update(dt, m.altitude, m.onGround)
      loop:setpoints({ altitude = pr.targetAlt, pitch = 0, roll = 0,
        heading = heading0, swayPos = swayPos0, surgePos = surgePos0 })
      loop:arm(pr.active)
      local diag = loop:cycle(dt, m)
      if diag.mode == "DAMPED" then profile:abort() end
      local dem = diag.demands or {}
      local sample = { t = (now - t0)/1000, dt = dt, phase = pr.phase, mode = diag.mode,
        sp_alt = pr.targetAlt, alt = m.altitude, vSpeed = m.vSpeed, pitch = m.pitch,
        roll = m.roll, heading = m.heading, yawRate = m.yawRate, swayVel = m.swayVel,
        surgeVel = m.surgeVel, swayPos = m.swayPos, surgePos = m.surgePos,
        onGround = m.onGround, heave = dem.heave, dPitch = dem.pitch, dRoll = dem.roll,
        dYaw = dem.yaw, dSway = dem.sway, dSurge = dem.surge, duties = diag.duties }
      summary:add(sample)
      part.write(Inst.formatRow(sample) .. "\n")
      if pr.done then return end
      timer = os.startTimer(0)
    elseif ev[1] == "key" then
      if ev[2] == keys.space then profile:begin(); print("LAUNCH")
      elseif ev[2] == keys.q then profile:abort(); print("ABORT -> landing") end
    end
  end
end

local function run()
  local config = loadConfig()
  local backend = Backend.new(require("fcs.io.shim"), config)
  local loop = buildLoop(backend)

  print("EH2 HOVER TEST -- measuring baseline (hold still)...")
  local baseAlt, heading0, swayPos0, surgePos0 = baseline(backend)
  print(string.format("baseAlt %.2f  heading0 %.3f", baseAlt, heading0))

  local pcfg = { baseAlt = baseAlt }
  for k, v in pairs(tuning.profile) do pcfg[k] = v end
  local profile = Profile.new(pcfg)
  local summary = Inst.Summary.new()

  local part = fs.open(PART_PATH, "w"); part.write(Inst.header() .. "\n")
  print("Ready. Fuel ON. Press SPACE to launch, Q to abort.")

  local ok, err = pcall(flight, backend, loop, profile, summary, heading0, swayPos0, surgePos0, part)

  -- ALWAYS stop thrust, however we exited
  loop:arm(false)
  pcall(function() loop:cycle(0, backend:sensors()) end)
  killThrusters(backend)
  part.close()
  if not ok then print("FLIGHT ERROR: " .. tostring(err)) end

  -- compose final log: summary header + CSV rows from the crash-safe part file
  local rows = ""
  local pf = fs.open(PART_PATH, "r"); if pf then rows = pf.readAll() or ""; pf.close() end
  local out = fs.open(LOG_PATH, "w")
  out.write(Inst.formatSummary(summary:finalize()) .. "\n\n" .. rows)
  out.close()

  print("")
  print(Inst.formatSummary(summary:finalize()))
  print("")
  print("Log written: " .. LOG_PATH)
  local okp = pcall(function() shell.run("pastebin", "put", LOG_PATH) end)
  if not okp then print("(pastebin unavailable -- grab " .. LOG_PATH .. " manually)") end
end

return { run = run }
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — `test_hover_test` require-loads the module (proving it parses and all its top-level `require`s resolve headless; `run()` itself is never called by the suite).

- [ ] **Step 6: Commit**

```bash
git add tools/hover_test.lua tests/test_hover_test.lua tests/run_headless.sh
git commit -m "feat(bringup): in-game hover test shell -- profile-driven flight + logging"
```

- [ ] **Step 7: In-game manual checklist (pilot, record results — do not automate)**
  - Install via Task 6, run `hovertest` on the FCS PC.
  - Confirm baseline prints a sane `baseAlt`.
  - Fuel ON, press SPACE; watch climb to ~+5, hold ~10 s, auto-descend, land.
  - Confirm `Q` aborts to a descent; confirm pulling fuel drops thrust.
  - Retrieve `/eh2_hover_log.csv` (pastebin code or the file) and post it.

---

### Task 6: `tools/install_hovertest.lua` — installer + `/hovertest` launcher

**Files:**
- Create: `tools/install_hovertest.lua`

**Interfaces:**
- Consumes: nothing (standalone installer, mirrors `tools/install_probe.lua`).
- Produces: fetches the full runtime dependency set from GitHub raw and writes a `/hovertest` launcher.

- [ ] **Step 1: Write the implementation** — create `tools/install_hovertest.lua`:

```lua
-- EasyHover 2 -- hover bring-up test installer.
-- Fetches tools/hover_test.lua and its full runtime dependency set from GitHub, then writes a
-- launcher (/hovertest) that sets package.path so require resolves the modules.
-- Run on the FCS PC with:
--   wget run https://raw.githubusercontent.com/maar-10/EasyHover2/main/tools/install_hovertest.lua
-- Re-run any time to update. Safe to run repeatedly (overwrites the code files).

local BASE = "https://raw.githubusercontent.com/maar-10/EasyHover2/main/"
local FILES = {
  "tools/hover_test.lua",
  "fcs/tuning.lua",
  "fcs/bringup/profile.lua",
  "fcs/bringup/instrument.lua",
  "fcs/runtime/loop.lua",
  "fcs/schemes/level_flight.lua",
  "fcs/mixer/level_flight.lua",
  "fcs/actuate/pwm.lua",
  "fcs/actuate/sigma_delta.lua",
  "fcs/control/pid.lua",
  "fcs/control/heading.lua",
  "fcs/control/translate.lua",
  "fcs/safety/oscillation.lua",
  "fcs/envelope.lua",
  "fcs/frame.lua",
  "fcs/angle.lua",
  "fcs/io/backend.lua",
  "fcs/io/shim.lua",
  "fcs/io/hwconfig.lua",
}

if not http then
  error("HTTP API is disabled -- enable http in the CC config to fetch files.", 0)
end

local function fetch(path)
  io.write("  " .. path .. " ... ")
  local h, err = http.get(BASE .. path)
  if not h then error("\nFAILED to fetch " .. path .. ": " .. tostring(err), 0) end
  local body = h.readAll()
  h.close()
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  f.write(body)
  f.close()
  print("ok (" .. #body .. " bytes)")
end

print("EasyHover 2 hover-test installer")
print("fetching files:")
for _, p in ipairs(FILES) do fetch(p) end

local LAUNCHER = 'package.path = "/?.lua;/?/init.lua;" .. package.path\n'
              .. 'require("tools.hover_test").run()\n'
local lf = fs.open("hovertest", "w")
lf.write(LAUNCHER)
lf.close()

print("")
print("Installed. Fuel the craft, then start the hover test with:")
print("  hovertest")
```

- [ ] **Step 2: Verify the repo is still green** — the installer is not part of the suite; this guards you did not break anything and lets you eyeball the file.

Run: `bash tests/run_headless.sh`
Expected: OK — unaffected. Eyeball `tools/install_hovertest.lua`: FILES has 19 entries, launcher mirrors the probe installer's `package.path` line + `require("tools.hover_test").run()`.

- [ ] **Step 3: Commit**

```bash
git add tools/install_hovertest.lua
git commit -m "feat(bringup): installer fetches hover test + deps, writes /hovertest launcher"
```

- [ ] **Step 4: Tag the completed plan**

```bash
git tag -a hover-bringup -m "Hover bring-up test: profile + instrumentation + tool + installer"
```

---

## Self-Review

**Spec coverage:**
- §2 profile (ramps, phases, defaults) — Task 2 + Task 1 (`tuning.profile`). ✓
- §3 controls (space/Q, event loop) — Task 5 (`flight` event loop). ✓
- §4 safety cutoffs (watchdog, overshoot, DAMPED→abort) — Task 2 (watchdog/overshoot) + Task 5 (`diag.mode=="DAMPED"` → `profile:abort()`). ✓
- §5.1 `fcs/tuning.lua` — Task 1. ✓
- §5.2 profile — Task 2. ✓
- §5.3 instrument — Task 3. ✓
- §5.4 Loop enhancements — Task 4. ✓
- §5.5 shell (baseline, event loop, log compose, pastebin) — Task 5. ✓
- §6 delivery (dedicated installer + `/hovertest`) — Task 6. ✓
- §7 testing (profile, instrument, loop suites + shell smoke) — Tasks 2/3/4/5. ✓
- §8 out of scope (fuel manual, no comms) — honored; shell never drives the fuel relay, but `killThrusters` guarantees thrust-off on any exit (a safety addition, not fuel automation). ✓

**Placeholder scan:** no TBD/TODO; every code step is literal. ✓

**Type consistency:**
- `Profile:update` returns `{phase, targetAlt, active, done}` (Task 2) — consumed in Task 5 as `pr.phase/pr.targetAlt/pr.active/pr.done`. ✓
- `Loop:cycle(dt, m)` returns `{mode, m, demands, duties}` (Task 4) — consumed in Task 5 as `diag.mode/diag.demands/diag.duties`. ✓
- `Inst.header/formatRow/Summary/formatSummary` (Task 3) — used in Task 5 with the same sample field names the Summary test uses. ✓
- `tuning.gains/pwmPeriod/caps/osc/dtMax/profile` (Task 1) — consumed in Task 5 (`buildLoop`, `pcfg`). ✓
- `backend:liftIds/lateralIds/mainIds/frontalIds` used by `killThrusters` exist on the real backend (`fcs/io/backend.lua`). ✓

Sample table is built once per cycle in Task 5's `flight` (hoisted into a `sample` local, used by both `summary:add` and `formatRow`) — no DRY smell.
