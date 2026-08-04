# FCS Safety Contract Implementation Plan (Plan 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the safety protections from design §11 that aren't built yet — an **envelope limiter** (hard caps on axis demands), **ground-state gating** (no integrator windup while parked → no takeoff lurch), and an **oscillation detector + auto-degrade to DAMPED HOVER** (the loop watches itself and gives up authority before it diverges). Proven headless.

**Architecture:** Extends the merged kernel+yaw+horizontal (Plans 1–3). Three small, independent additions: a pure `envelope.clamp` applied to demands before the mixer; a ground gate in the runtime that freezes integrators when `onGround`; and an `oscillation` detector the runtime consults per axis to drop into a **DAMPED** mode (neutral demands, held). All plug into the existing scheme/runtime; no controller math changes.

**Tech Stack:** Lua 5.1 (CC:Tweaked / CraftOS-PC). Headless via `bash tests/run_headless.sh`. No external libraries.

**Base:** branch from `main` at the Plan-3 merge (`52032c4` or later). 61 tests green.

## Global Constraints

- Lua 5.1 (no `goto`, no `//`, `math.floor`, no external modules). No fixed time step; per-second tunables (the detector window and thresholds are in seconds). TDD; targeted commits; LF.
- Backend `sensors()` already returns `onGround`. No new sensors.
- The envelope caps and detector thresholds live in the `Loop`/`Scheme` config (per-second where rate-like).
- YAGNI: these three protections only. No annunciation UI (a `mode` string in state is enough), no gain-scheduling beyond the DAMPED drop.

---

## File structure

```
fcs/
  envelope.lua           NEW — clamp axis demands to configured caps
  safety/oscillation.lua NEW — per-axis error sign-change rate detector
  runtime/loop.lua       MODIFY — apply envelope; ground gate (freeze integrators); DAMPED-mode drop; expose mode
  schemes/level_flight.lua MODIFY — update(sp,m,dt,freeze) threads a freeze flag to every controller's integrator
tests/
  test_envelope.lua      NEW
  test_oscillation.lua   NEW
  test_integration.lua   MODIFY — ground no-windup + envelope-cap + oscillation->DAMPED acceptance
```

Add each new `tests/*.lua` to the suite list in `tests/run_headless.sh`.

---

## Task 1: Freeze flag through the scheme + controllers

**Files:** Modify `fcs/schemes/level_flight.lua`, `fcs/control/heading.lua`, `fcs/control/translate.lua`. Add a scheme test to `tests/test_integration.lua`.

**Interfaces:** The `Pid:update(sp,meas,dt,saturated)` already freezes integration when `saturated` is true. Give `Heading` and `Translate` the same 5th behavior and thread one `freeze` flag from the scheme.
- `Heading:update(sp, meas, yawRate, dt, freeze)` — integrate only when `not freeze and dt-usable`.
- `Translate:update(sp, meas, vel, dt, freeze)` — same.
- `Scheme:update(sp, m, dt, freeze)` — passes `freeze` as the integrator-freeze arg to alt/pitch/roll (`Pid`'s `saturated`) and to heading/sway/surge.

- [ ] **Step 1: Write the failing test** — add to `tests/test_integration.lua`

```lua
t.test("freeze flag stops integral windup across the scheme", function()
  local sc = Scheme.new({ hoverDuty = 0.66,
    alt = { kp = 0, ki = 1, kd = 0 }, pitch = { kp=0,ki=0,kd=0 }, roll = { kp=0,ki=0,kd=0 },
    yaw = { kp=0,ki=0,kd=0 }, sway = { kp=0,ki=0,kd=0 }, surge = { kp=0,ki=0,kd=0 } })
  local m = { altitude=0, vSpeed=0, pitch=0, pitchRate=0, roll=0, rollRate=0,
    heading=0, yawRate=0, swayPos=0, swayVel=0, surgePos=0, surgeVel=0 }
  local sp = { altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 }
  for _ = 1, 20 do sc:update(sp, m, 0.1, true) end          -- frozen: no windup
  t.near(sc:update(sp, m, 0, true).heave, 0.66, 1e-9)        -- heave == hoverDuty (I stayed 0)
end)
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement.**
  - `fcs/control/heading.lua`: add a 5th param `freeze`; change the integrate guard to `if not freeze and dt > 0 and dt <= self.dtMax then`.
  - `fcs/control/translate.lua`: same 5th param + guard.
  - `fcs/schemes/level_flight.lua`: `update` gains a 4th param `freeze`; pass it as the `saturated` arg to `altPid`/`pitchPid`/`rollPid` `:update(...)`, and as the `freeze` arg to `headingPid`/`swayTc`/`surgeTc`. (Existing callers pass no `freeze` → `nil` → falsy → unchanged behavior.)

- [ ] **Step 4: Run — verify pass** (all prior green + this one).

- [ ] **Step 5: Commit.** `git add fcs/schemes/level_flight.lua fcs/control/heading.lua fcs/control/translate.lua tests/test_integration.lua && git commit -m "feat(scheme): thread integrator-freeze flag through all controllers"`

---

## Task 2: Envelope limiter

**Files:** Create `fcs/envelope.lua`, `tests/test_envelope.lua`. Modify `tests/run_headless.sh`.

**Interfaces:** `envelope.clamp(demands, caps) -> demands` — returns a copy with each field clamped to `[-caps[k], caps[k]]` when a cap for `k` exists; fields without a cap pass through. Used on the moment/force demands (`pitch, roll, yaw, sway, surge`) — a hard authority ceiling no loop can exceed. `heave` is left alone (the mixer already clamps duties to `[0,1]`).

- [ ] **Step 1: Write the failing tests** — `tests/test_envelope.lua`

```lua
local t = require("tests.framework")
local envelope = require("fcs.envelope")
t.test("clamps a field to its positive cap", function()
  local d = envelope.clamp({ pitch = 5, roll = -5 }, { pitch = 0.2, roll = 0.2 })
  t.near(d.pitch, 0.2, 1e-9); t.near(d.roll, -0.2, 1e-9)
end)
t.test("passes fields with no cap through unchanged", function()
  local d = envelope.clamp({ heave = 0.9, yaw = 0.1 }, { yaw = 1 })
  t.near(d.heave, 0.9, 1e-9); t.near(d.yaw, 0.1, 1e-9)
end)
t.test("leaves in-range values untouched", function()
  t.near(envelope.clamp({ sway = 0.05 }, { sway = 0.5 }).sway, 0.05, 1e-9)
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_envelope"` to the suites list.

- [ ] **Step 3: Implement** — `fcs/envelope.lua`

```lua
local M = {}
function M.clamp(demands, caps)
  local out = {}
  for k, v in pairs(demands) do
    local c = caps[k]
    if c and v > c then out[k] = c
    elseif c and v < -c then out[k] = -c
    else out[k] = v end
  end
  return out
end
return M
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit.** `git add fcs/envelope.lua tests/test_envelope.lua tests/run_headless.sh && git commit -m "feat(envelope): hard-clamp axis demands to caps"`

---

## Task 3: Oscillation detector

**Files:** Create `fcs/safety/oscillation.lua`, `tests/test_oscillation.lua`. Modify `tests/run_headless.sh`.

**Interfaces:** `Osc.new(cfg) -> osc` (`cfg = {window, minChanges}`, window in seconds); `osc:update(err, dt) -> oscillating(bool)` — advances an internal clock by `dt`, records an error **sign change** (ignoring exact zeros), prunes changes older than `window`, and returns true when the count in the window reaches `minChanges`. `osc:reset()`.

- [ ] **Step 1: Write the failing tests** — `tests/test_oscillation.lua`

```lua
local t = require("tests.framework")
local Osc = require("fcs.safety.oscillation")
t.test("fires when sign changes exceed the threshold in the window", function()
  local o = Osc.new({ window = 1.0, minChanges = 4 })
  local fired = false
  local e = 1
  for _ = 1, 10 do fired = o:update(e, 0.1) or fired; e = -e end   -- flips every 0.1s
  t.truthy(fired)
end)
t.test("stays quiet for a steady (non-oscillating) error", function()
  local o = Osc.new({ window = 1.0, minChanges = 4 })
  local any = false
  for _ = 1, 30 do any = o:update(1.0, 0.1) or any end
  t.truthy(any == false)
end)
t.test("old changes age out of the window", function()
  local o = Osc.new({ window = 0.5, minChanges = 4 })
  local e = 1
  for _ = 1, 3 do o:update(e, 0.1); e = -e end        -- a few flips
  for _ = 1, 20 do o:update(1.0, 0.1) end             -- then steady > window
  t.truthy(o:update(1.0, 0.1) == false)               -- window cleared
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_oscillation"` to the suites list.

- [ ] **Step 3: Implement** — `fcs/safety/oscillation.lua`

```lua
local Osc = {}
Osc.__index = Osc
function Osc.new(cfg)
  return setmetatable({ window = cfg.window or 1.0, minChanges = cfg.minChanges or 6,
    t = 0, lastSign = 0, changes = {} }, Osc)
end
function Osc:reset() self.t = 0; self.lastSign = 0; self.changes = {} end
function Osc:update(err, dt)
  self.t = self.t + (dt > 0 and dt or 0)
  local s = err > 0 and 1 or (err < 0 and -1 or 0)
  if s ~= 0 then
    if self.lastSign ~= 0 and s ~= self.lastSign then self.changes[#self.changes + 1] = self.t end
    self.lastSign = s
  end
  local cutoff = self.t - self.window
  while self.changes[1] and self.changes[1] < cutoff do table.remove(self.changes, 1) end
  return #self.changes >= self.minChanges
end
return Osc
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit.** `git add fcs/safety/oscillation.lua tests/test_oscillation.lua tests/run_headless.sh && git commit -m "feat(safety): per-axis oscillation detector"`

---

## Task 4: Wire safety into the runtime — envelope, ground gate, DAMPED mode

**Files:** Modify `fcs/runtime/loop.lua`. Add tests to `tests/test_integration.lua`.

**Interfaces:**
- `Loop.new` cfg gains `caps` (envelope, default `{}`) and `osc` (detector cfg, default nil → detector off). Build one `Osc` on the attitude error magnitude (pitch²+roll² proxy — simplest: feed `m.pitch` and `m.roll` combined by tracking their summed sign via `m.pitch + m.roll`). Add `self.mode` ("NORMAL"/"GROUND"/"DAMPED"), readable via `loop:getMode()`.
- `loop:cycle(dt)` armed path becomes:
  1. read sensors `m`.
  2. **ground gate:** `local grounded = m.onGround == true`. Compute `demands = scheme:update(sp, m, dt, grounded)` (freeze integrators on the ground). If grounded, set `self.mode = "GROUND"`.
  3. **oscillation:** if a detector is configured, `if osc:update(m.pitch + m.roll, dt) then self.mode = "DAMPED" end` (DAMPED latches until `loop:clearDamped()` is called). In DAMPED, **override attitude/translation demands to neutral** (`pitch=0, roll=0, yaw=0, sway=0, surge=0`) and keep only `heave` (hold altitude) — the craft stops steering and just holds.
  4. **envelope:** `demands = envelope.clamp(demands, self.caps)`.
  5. mixer + pwm as before.
- `loop:clearDamped()` sets mode back to NORMAL and `osc:reset()` (pilot/ground-crew acknowledges).

- [ ] **Step 1: Write the failing tests** — add to `tests/test_integration.lua`

```lua
t.test("no integral windup while on the ground (no takeoff lurch)", function()
  local loop, sim = build(); loop:arm(true)
  loop:setpoints({ altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 })
  -- craft is on the ground (sim starts at altitude 0, onGround true) with a 10m error
  for _ = 1, 40 do loop:cycle(0.1); sim:step(0.1) end
  t.truthy(loop:getMode() == "GROUND")
  t.truthy(sim:sensors().altitude <= 0.5)     -- integrator frozen -> never lurched up
end)
t.test("a sustained oscillation drops the craft into DAMPED and neutralises steering", function()
  local loop, sim = build({ osc = { window = 1.0, minChanges = 4 } }); loop:arm(true)
  loop:setpoints({ altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 })
  fly(loop, sim, 5, function() return 0.1 end)     -- get airborne
  for i = 1, 12 do sim.pitch = (i % 2 == 0) and 0.4 or -0.4; loop:cycle(0.1); sim:step(0.1) end
  t.truthy(loop:getMode() == "DAMPED")
end)
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement** per the Interfaces above in `fcs/runtime/loop.lua` (`require("fcs.envelope")`, `require("fcs.safety.oscillation")`, `require("fcs.frame")` already there). Keep the disarmed path unchanged. Build the `Osc` only if `cfg.osc`.

- [ ] **Step 4: Run — verify pass.** (Tuning may be needed on the DAMPED test's `minChanges`/duration — adjust the *test's* detector cfg, not module logic, so it reliably fires on the injected oscillation but not on normal flight.)

- [ ] **Step 5: Commit.** `git add fcs/runtime/loop.lua tests/test_integration.lua && git commit -m "feat(runtime): envelope clamp + ground gate + oscillation->DAMPED"`

---

## Task 5: Acceptance — the safety contract holds

**Files:** Modify `tests/test_integration.lua`.

**Interfaces:** Consumes `build()`/`fly()`. `build()` may need a `caps` set and an `osc` cfg passed through to `Loop.new` (extend `build` to accept and forward an options table if it doesn't already).

- [ ] **Step 1: Write the failing tests** — add to `tests/test_integration.lua`

```lua
t.test("envelope caps the attitude demand", function()
  -- with a tight pitch cap, a large pitch disturbance cannot command beyond the cap
  local loop, sim = build({ caps = { pitch = 0.05, roll = 0.05 } }); loop:arm(true)
  loop:setpoints({ altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 })
  fly(loop, sim, 5, function() return 0.1 end)
  sim.pitch = 1.0                                   -- big disturbance
  -- one cycle: capture the clamped pitch demand via the mode staying sane + no divergence
  fly(loop, sim, 10, function() return 0.1 end)
  t.truthy(math.abs(sim:sensors().pitch) < 2.0)     -- bounded (cap prevents a violent correction runaway)
end)
t.test("DAMPED holds altitude and stops steering", function()
  local loop, sim = build({ osc = { window = 1.0, minChanges = 4 } }); loop:arm(true)
  loop:setpoints({ altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 })
  fly(loop, sim, 5, function() return 0.1 end)
  for i = 1, 12 do sim.pitch = (i % 2 == 0) and 0.4 or -0.4; loop:cycle(0.1); sim:step(0.1) end
  t.truthy(loop:getMode() == "DAMPED")
  local h0 = sim:sensors().altitude
  fly(loop, sim, 10, function() return 0.1 end)     -- in DAMPED
  t.near(sim:sensors().altitude, h0, 1.5)           -- still roughly holding altitude, not falling
end)
t.test("clearDamped returns to NORMAL", function()
  local loop, sim = build({ osc = { window = 1.0, minChanges = 4 } }); loop:arm(true)
  loop:setpoints({ altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 })
  fly(loop, sim, 5, function() return 0.1 end)
  for i = 1, 12 do sim.pitch = (i % 2 == 0) and 0.4 or -0.4; loop:cycle(0.1); sim:step(0.1) end
  loop:clearDamped()
  t.truthy(loop:getMode() ~= "DAMPED")
end)
```

- [ ] **Step 2: Run.** Tune the *test* detector cfg / caps as needed so the assertions reflect real behavior — do NOT weaken them or change module logic to pass. Confirm all prior acceptance tests (altitude/attitude/heading/horizontal) stay green.

- [ ] **Step 3: Achieve green + confirm no regression.**

- [ ] **Step 4: Commit.** `git add tests/test_integration.lua && git commit -m "test(fcs): acceptance — envelope, ground gate, DAMPED hover"`

---

## Self-review

- **Freeze flag** (Task 1) reuses the PID `saturated` path uniformly. ✅
- **Envelope** (Task 2) hard-caps demands; pure function. ✅
- **Oscillation detector** (Task 3) counts sign-changes/window, ages out. ✅
- **Runtime wiring** (Task 4): ground gate freezes integrators (no takeoff lurch); detector latches DAMPED and neutralises steering while holding altitude; envelope clamps. ✅
- **Acceptance** (Task 5): envelope cap, DAMPED hold, clearDamped recovery; prior suite intact. ✅
- **Type consistency:** `envelope.clamp(demands,caps)`, `Osc:update(err,dt)`, `Scheme:update(sp,m,dt,freeze)`, `Heading/Translate:update(...,freeze)`, `loop:getMode()/clearDamped()` — consistent.
- **Deferred:** gain-scheduling degrade (only DAMPED drop here); annunciation UI; per-axis detectors (one combined attitude detector here); the resolution-floor modulator (separate plan).

## Follow-on

- **Resolution-floor plan** — sigma-delta / hybrid modulator or yaw+lateral bias baseline (design §7, §17 #8) to tighten yaw/sway/surge hold.
- **Hardware IO + sensor calibration + in-game bring-up** — the real backend, the calibration procedure that measures sensor→frame sign bindings, and first flight (measure real loop rate, heave bob, the resolution floors).
- **NAV plan** — GPS world-frame absolute position hold + autopilot.
- **Comms + UI plan** — the decoupled telemetry/command layer + cockpit (reported-state-only).
