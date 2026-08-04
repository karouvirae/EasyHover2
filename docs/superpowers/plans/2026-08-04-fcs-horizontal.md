# FCS Horizontal Translation + Position Hold Implementation Plan (Plan 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The craft holds its horizontal position (damps drift to zero) and can be translated fore/aft and left/right, holding the new position — a leashed setpoint caps the speed. Proven headless in the simulator, in the **craft frame**.

**Architecture:** Extends the merged kernel + yaw (Plans 1–2). The 4 **lateral** thrusters gain a **sway** (collective) role on top of their yaw (differential) role — combined on one bang-bang duty via an orthogonal sign trick. The **main** thruster (rear-facing) gives forward surge; the **2 frontal** thrusters (forward-facing) give reverse/brake. Two **translation controllers** (sway, surge) mirror the heading controller: P+I on position error + velocity damping taken **from the velocity sensors**. A **leash** bounds how far a setpoint can lead the craft, which is what caps flight speed.

**Tech Stack:** Lua 5.1 (CC:Tweaked / CraftOS-PC). Headless via `bash tests/run_headless.sh`. No external libraries.

**Base:** branch from `main` at the Plan-2 merge (`fca9dd2` or later). 41 tests green.

## Global Constraints

- Lua 5.1 (no `goto`, no `//`, `math.floor`, no external modules). No fixed time step; per-second tunables. TDD; targeted commits; LF.
- **Craft frame only.** Sway = +right, surge = +forward, both relative to the craft's nose. Absolute world-frame / GPS station-keeping (returning to an exact XZ point across yaw maneuvers) is the **NAV plan**, not this one. Position here is integrated craft-frame velocity (drifts slowly — acceptable for the core; GPS makes it drift-free later).
- **Signs measured, never assumed.** The sim's sway signs are fixed and pinned by direction tests; real lateral/main/frontal geometry is calibration-bound (the `SWAY_DIR`/thruster-facing maps are the seam).
- **Backend interface (extended):** `backend:sensors()` also returns `swayVel, surgeVel, swayPos, surgePos`; `backend:mainIds()` / `backend:frontalIds()` return those thruster ids; `setThruster(id,on)` already handles any id.
- YAGNI: translation + drift-damping + leash only. No world-frame rotation, no obstacle avoidance, no NAV.

---

## File structure

```
fcs/
  frame.lua              MODIFY — add MAIN, FRONTAL ids
  mixer/level_flight.lua MODIFY — mixLateral(sway,yaw) [sway+yaw combined]; mixSurge(surge)
  control/translate.lua  NEW — position P+I + velocity-sensor damping (linear; no wrap)
  leash.lua              NEW — ramp a setpoint toward a target at a speed, clamped to ±maxLead of position
  schemes/level_flight.lua MODIFY — add sway/surge loops; return sway,surge in demands
  runtime/loop.lua       MODIFY — disarmed path zeroes MAIN + FRONTAL too
tests/
  sim.lua                MODIFY — horizontal plant (sway/surge vel + pos) from lateral/main/frontal
  test_translate.lua     NEW
  test_leash.lua         NEW
  test_surge_mixer.lua   NEW
  test_sim_horizontal.lua NEW
  test_integration.lua   MODIFY — drift-damping + translation + leash-cap acceptance
```

Add each new `tests/*.lua` to the suite list in `tests/run_headless.sh`'s generated `startup.lua`.

**Key sign maps (must match between mixer and sim):**
- `YAW_DIR  = { YFL=1, YFR=-1, YRL=-1, YRR=1 }` (already exists — yaw couple).
- `SWAY_DIR = { YFL=1, YFR=-1, YRL=1,  YRR=-1 }` (NEW — each lateral thruster's +right push).
- These two patterns are **orthogonal** (`Σ YAW·SWAY = 0`), so `duty_i = clamp(SWAY_DIR[i]·sway + YAW_DIR[i]·yaw)` delivers `Σ duty·SWAY ∝ sway` and `Σ duty·YAW ∝ yaw` independently — sway and yaw don't cross-talk (verified in Task 1's test).

---

## Task 1: Surge mixer + combined lateral (sway+yaw) mixer

**Files:** Modify `fcs/frame.lua`, `fcs/mixer/level_flight.lua`. Create `tests/test_surge_mixer.lua`. Modify `tests/run_headless.sh`.

**Interfaces:**
- `frame.MAIN = {"MAIN"}`; `frame.FRONTAL = {"FRL","FRR"}`.
- `Mixer:mixLateral(sway, yaw) -> {[id]=duty}` over the 4 lateral ids: `clamp(SWAY_DIR[id]*sway + YAW_DIR[id]*yaw)`.
- `Mixer:mixYaw(yaw)` keeps working, now delegating: `return self:mixLateral(0, yaw)`.
- `Mixer:mixSurge(surge) -> {MAIN=..,FRL=..,FRR=..}`: `surge>0` → `MAIN=clamp(surge)`, frontal 0; `surge<0` → `FRL=FRR=clamp(-surge)`, MAIN 0; `surge==0` → all 0.

- [ ] **Step 1: Write the failing tests** — `tests/test_surge_mixer.lua`

```lua
local t = require("tests.framework")
local Mixer = require("fcs.mixer.level_flight")
t.test("pure sway right fires the +right thrusters, no yaw cross-talk", function()
  local d = Mixer.new():mixLateral(0.4, 0)
  t.near(d.YFL, 0.4, 1e-9); t.near(d.YRL, 0.4, 1e-9)   -- +right pair
  t.near(d.YFR, 0, 1e-9);   t.near(d.YRR, 0, 1e-9)
end)
t.test("sway and yaw combine without cross-talk (orthogonal)", function()
  -- small sway + small yaw; each thruster gets the sum, clamped
  local d = Mixer.new():mixLateral(0.2, 0.2)
  t.near(d.YFL, 0.4, 1e-9)   -- SWAY_DIR +1, YAW_DIR +1 -> 0.4
  t.near(d.YFR, 0, 1e-9)     -- SWAY_DIR -1, YAW_DIR -1 -> -0.4 -> clamp 0
  t.near(d.YRL, 0, 1e-9)     -- SWAY_DIR +1, YAW_DIR -1 -> 0
  t.near(d.YRR, 0, 1e-9)     -- SWAY_DIR -1, YAW_DIR +1 -> 0
end)
t.test("surge forward fires MAIN only", function()
  local d = Mixer.new():mixSurge(0.5)
  t.near(d.MAIN, 0.5, 1e-9); t.near(d.FRL, 0, 1e-9); t.near(d.FRR, 0, 1e-9)
end)
t.test("surge reverse fires the frontal brakes only", function()
  local d = Mixer.new():mixSurge(-0.5)
  t.near(d.FRL, 0.5, 1e-9); t.near(d.FRR, 0.5, 1e-9); t.near(d.MAIN, 0, 1e-9)
end)
t.test("mixYaw still works (delegates to mixLateral)", function()
  local d = Mixer.new():mixYaw(0.4)
  t.near(d.YFL, 0.4, 1e-9); t.near(d.YRR, 0.4, 1e-9)
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_surge_mixer"` to the suites list in `tests/run_headless.sh`.

- [ ] **Step 3: Implement.**
  - `fcs/frame.lua`: add `MAIN = { "MAIN" }` and `FRONTAL = { "FRL", "FRR" }` to the returned table (keep `LIFT`, `LATERAL`).
  - `fcs/mixer/level_flight.lua`: add `local SWAY_DIR = { YFL = 1, YFR = -1, YRL = 1, YRR = -1 }` next to `YAW_DIR`. Then:

```lua
function Mixer:mixLateral(sway, yaw)
  local out = {}
  for id, ydir in pairs(YAW_DIR) do
    out[id] = clamp((SWAY_DIR[id] or 0) * (sway or 0) + ydir * (yaw or 0))
  end
  return out
end
function Mixer:mixYaw(yaw) return self:mixLateral(0, yaw) end
function Mixer:mixSurge(surge)
  surge = surge or 0
  return {
    MAIN = surge > 0 and clamp(surge) or 0,
    FRL  = surge < 0 and clamp(-surge) or 0,
    FRR  = surge < 0 and clamp(-surge) or 0,
  }
end
```
  (Keep the existing `mix` for now — it's rewired in Task 5.)

- [ ] **Step 4: Run — verify pass** (all green, count grows by 5).

- [ ] **Step 5: Commit.** `git add fcs/frame.lua fcs/mixer/level_flight.lua tests/test_surge_mixer.lua tests/run_headless.sh && git commit -m "feat(mixer): combined sway+yaw lateral mixer + surge mixer"`

---

## Task 2: Sim horizontal plant

**Files:** Modify `tests/sim.lua`. Create `tests/test_sim_horizontal.lua`. Modify `tests/run_headless.sh`.

**Interfaces:** `Sim` tracks `swayVel, surgeVel, swayPos, surgePos`. `sim:step` adds: sway force `= Σ SWAY_DIR[id]·fPerLat·(lateral on?)`; surge force `= fMain·(MAIN on?) − fFrontal·Σ(frontal on?)`. `swayAccel=swayForce/mass`, `surgeAccel=surgeForce/mass`; integrate vel then pos. `sim:sensors()` adds the four. `sim:mainIds()`/`sim:frontalIds()` return `frame.MAIN`/`frame.FRONTAL`. Config: `fMain` (default 20), `fFrontal` (default 10). The sim `SWAY_DIR` must equal the mixer's.

- [ ] **Step 1: Write the failing tests** — `tests/test_sim_horizontal.lua`

```lua
local t = require("tests.framework")
local Sim = require("tests.sim")
local function cfg() return { mass=4, g=10, fPer=15, inertia=2, armX=1, armZ=1,
  fPerLat=8, yawInertia=8, fMain=20, fFrontal=10 } end
t.test("firing the +right lateral pair sways right (swayVel > 0)", function()
  local s = Sim.new(cfg()); s:setThruster("YFL", true); s:setThruster("YRL", true)
  s:step(0.1); t.truthy(s:sensors().swayVel > 0)
end)
t.test("MAIN thruster surges forward (surgeVel > 0)", function()
  local s = Sim.new(cfg()); s:setThruster("MAIN", true)
  s:step(0.1); t.truthy(s:sensors().surgeVel > 0)
end)
t.test("frontal thrusters brake/reverse (surgeVel < 0)", function()
  local s = Sim.new(cfg()); s:setThruster("FRL", true); s:setThruster("FRR", true)
  s:step(0.1); t.truthy(s:sensors().surgeVel < 0)
end)
t.test("position integrates velocity", function()
  local s = Sim.new(cfg()); s:setThruster("MAIN", true)
  s:step(0.1); s:step(0.1); t.truthy(s:sensors().surgePos > 0)
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_sim_horizontal"` to the suites list.

- [ ] **Step 3: Implement** — in `tests/sim.lua`:
  - add `local SWAY_DIR = { YFL = 1, YFR = -1, YRL = 1, YRR = -1 }`.
  - `Sim.new`: init `self.swayVel, self.surgeVel, self.swayPos, self.surgePos = 0,0,0,0`; and `for _, id in ipairs(frame.MAIN) do self.on[id]=false end` and same for `frame.FRONTAL`.
  - add `function Sim:mainIds() return frame.MAIN end` and `function Sim:frontalIds() return frame.FRONTAL end`.
  - in `Sim:step`, after the yaw integration, add:

```lua
local sway, surge = 0, 0
for _, id in ipairs(frame.LATERAL) do
  if self.on[id] then sway = sway + SWAY_DIR[id] * self.cfg.fPerLat end
end
if self.on.MAIN then surge = surge + self.cfg.fMain end
for _, id in ipairs(frame.FRONTAL) do
  if self.on[id] then surge = surge - self.cfg.fFrontal end
end
self.swayVel = self.swayVel + (sway / self.cfg.mass) * dt
self.surgeVel = self.surgeVel + (surge / self.cfg.mass) * dt
self.swayPos = self.swayPos + self.swayVel * dt
self.surgePos = self.surgePos + self.surgeVel * dt
```

  - in `Sim:sensors()` add `swayVel, surgeVel, swayPos, surgePos`.

- [ ] **Step 4: Run — verify pass.** Guard-check: flip `SWAY_DIR` in the sim, confirm the sway direction test fails, restore.

- [ ] **Step 5: Commit.** `git add tests/sim.lua tests/test_sim_horizontal.lua tests/run_headless.sh && git commit -m "test(sim): horizontal plant (sway/surge vel + pos), signs pinned"`

---

## Task 3: Translation controller

**Files:** Create `fcs/control/translate.lua`, `tests/test_translate.lua`. Modify `tests/run_headless.sh`.

**Interfaces:** `Translate.new(cfg) -> tc`; `tc:update(posSp, posMeas, vel, dt) -> forceDemand`; `tc:reset()`. `cfg = {kp, ki, kd, iMin, iMax, dtMax}`. Law (identical to the heading controller minus the angle-wrap): `err = posSp - posMeas`; P+I integrates only when `dt`-usable, `i` clamped; damping `-kd*vel` (velocity from the sensor argument). Output `kp*err + i - kd*vel`.

- [ ] **Step 1: Write the failing tests** — `tests/test_translate.lua`

```lua
local t = require("tests.framework")
local Translate = require("fcs.control.translate")
t.test("commands positive force toward a positive position error", function()
  local c = Translate.new({ kp = 1, ki = 0, kd = 0 })
  t.near(c:update(2, 0, 0, 0.1), 2, 1e-9)
end)
t.test("damps proportionally to velocity", function()
  local c = Translate.new({ kp = 0, ki = 0, kd = 0.5 })
  t.near(c:update(0, 0, 3.0, 0.1), -1.5, 1e-9)
end)
t.test("integral accumulates and clamps", function()
  local c = Translate.new({ kp = 0, ki = 1, kd = 0, iMax = 0.5 })
  for _ = 1, 50 do c:update(1, 0, 0, 0.1) end
  t.near(c:update(1, 0, 0, 0), 0.5, 1e-9)
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_translate"` to the suites list.

- [ ] **Step 3: Implement** — `fcs/control/translate.lua`

```lua
local T = {}
T.__index = T
function T.new(cfg)
  local self = setmetatable({}, T)
  self.kp = cfg.kp or 0; self.ki = cfg.ki or 0; self.kd = cfg.kd or 0
  self.iMin = cfg.iMin or -math.huge; self.iMax = cfg.iMax or math.huge
  self.dtMax = cfg.dtMax or 0.5
  self:reset(); return self
end
function T:reset() self.i = 0 end
function T:update(sp, meas, vel, dt)
  local err = sp - meas
  if dt > 0 and dt <= self.dtMax then
    self.i = self.i + self.ki * err * dt
    if self.i > self.iMax then self.i = self.iMax elseif self.i < self.iMin then self.i = self.iMin end
  end
  return self.kp * err + self.i - self.kd * (vel or 0)
end
return T
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit.** `git add fcs/control/translate.lua tests/test_translate.lua tests/run_headless.sh && git commit -m "feat(translate): position P+I + velocity-sensor damping"`

---

## Task 4: Leash

**Files:** Create `fcs/leash.lua`, `tests/test_leash.lua`. Modify `tests/run_headless.sh`.

**Interfaces:** `leash.step(sp, target, pos, dt, speed, maxLead) -> newSp` — ramp `sp` toward `target` by at most `speed*dt`, then clamp to `[pos-maxLead, pos+maxLead]`. This is how a held translation input becomes a bounded moving setpoint: the setpoint chases the pilot's target at cruise `speed` but is never allowed to lead the craft's actual `pos` by more than `maxLead` — which caps the position error the controller sees, hence the speed.

- [ ] **Step 1: Write the failing tests** — `tests/test_leash.lua`

```lua
local t = require("tests.framework")
local leash = require("fcs.leash")
t.test("ramps toward the target at the speed limit", function()
  t.near(leash.step(0, 10, 0, 0.1, 2, 100), 0.2, 1e-9)   -- 2 m/s * 0.1s
end)
t.test("snaps to target when within a step", function()
  t.near(leash.step(0, 0.05, 0, 0.1, 2, 100), 0.05, 1e-9)
end)
t.test("clamps to maxLead ahead of position", function()
  -- far target, big speed, but leash caps the setpoint at pos+maxLead
  t.near(leash.step(0, 100, 5, 1.0, 100, 1.5), 6.5, 1e-9)  -- pos 5 + maxLead 1.5
end)
t.test("clamps behind position too", function()
  t.near(leash.step(0, -100, 5, 1.0, 100, 1.5), 3.5, 1e-9)
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_leash"` to the suites list.

- [ ] **Step 3: Implement** — `fcs/leash.lua`

```lua
local M = {}
function M.step(sp, target, pos, dt, speed, maxLead)
  local maxStep = speed * (dt > 0 and dt or 0)
  local d = target - sp
  if d > maxStep then sp = sp + maxStep
  elseif d < -maxStep then sp = sp - maxStep
  else sp = target end
  if sp > pos + maxLead then sp = pos + maxLead
  elseif sp < pos - maxLead then sp = pos - maxLead end
  return sp
end
return M
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit.** `git add fcs/leash.lua tests/test_leash.lua tests/run_headless.sh && git commit -m "feat(leash): speed-ramped, position-bounded setpoint"`

---

## Task 5: Wire translation into scheme, mixer, runtime

**Files:** Modify `fcs/schemes/level_flight.lua`, `fcs/mixer/level_flight.lua`, `fcs/runtime/loop.lua`. Add a scheme test to `tests/test_integration.lua`.

**Interfaces:**
- `Scheme.new` builds `self.swayTc = Translate.new(cfg.sway or {})` and `self.surgeTc = Translate.new(cfg.surge or {})`.
- `scheme:update(sp, m, dt)` also returns `sway = self.swayTc:update(sp.swayPos or 0, m.swayPos or 0, m.swayVel or 0, dt)` and `surge = self.surgeTc:update(sp.surgePos or 0, m.surgePos or 0, m.surgeVel or 0, dt)`; `reset()` resets both.
- `Mixer:mix(d)` now merges lift + `mixLateral(d.sway, d.yaw)` + `mixSurge(d.surge)`.
- `loop:cycle` disarmed path also zeroes `frame.MAIN` and `frame.FRONTAL`.

- [ ] **Step 1: Write the failing test** — add to `tests/test_integration.lua`

```lua
t.test("scheme emits sway/surge force toward a position setpoint", function()
  local sc = Scheme.new({ hoverDuty = 0.66,
    alt = { kp = 0.04, ki = 0.02, kd = 0.30, tauD = 0.2, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    roll  = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    yaw   = { kp = 0.5, ki = 0, kd = 0.2 },
    sway  = { kp = 0.3, ki = 0, kd = 0.4 },
    surge = { kp = 0.3, ki = 0, kd = 0.4 } })
  local m = { altitude=10, vSpeed=0, pitch=0, pitchRate=0, roll=0, rollRate=0,
    heading=0, yawRate=0, swayPos=0, swayVel=0, surgePos=0, surgeVel=0 }
  local d = sc:update({ altitude=10, pitch=0, roll=0, heading=0, swayPos=1, surgePos=-1 }, m, 0.1)
  t.truthy(d.sway > 0)     -- +swayPos error -> push right
  t.truthy(d.surge < 0)    -- -surgePos error -> push back
end)
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement.**
  - `fcs/schemes/level_flight.lua`: `local Translate = require("fcs.control.translate")`; in `new`, build `swayTc`/`surgeTc`; in `reset`, reset both; in `update`, add `sway`/`surge` to the returned demands.
  - `fcs/mixer/level_flight.lua`: rewrite `mix` to merge all groups:

```lua
function Mixer:mix(d)
  local h, p, r = d.heave or 0, d.pitch or 0, d.roll or 0
  local out = {
    FL = clamp(h + p + r), FR = clamp(h + p - r),
    RL = clamp(h - p + r), RR = clamp(h - p - r),
  }
  for id, duty in pairs(self:mixLateral(d.sway, d.yaw)) do out[id] = duty end
  for id, duty in pairs(self:mixSurge(d.surge)) do out[id] = duty end
  return out
end
```

  - `fcs/runtime/loop.lua`: in the disarmed branch, extend `zeros` to also include every `frame.MAIN` and `frame.FRONTAL` id.

- [ ] **Step 4: Run — verify pass** (all prior green + this one).

- [ ] **Step 5: Commit.** `git add fcs/schemes/level_flight.lua fcs/mixer/level_flight.lua fcs/runtime/loop.lua tests/test_integration.lua && git commit -m "feat(scheme): sway/surge translation wired through mixer + runtime"`

---

## Task 6: Acceptance — drift damping, translation, leash cap

**Files:** Modify `tests/test_integration.lua`. (Tuning task — adjust the `sway`/`surge` gains in `build()` until green; do NOT weaken assertions or change module logic.)

**Interfaces:** `build()` adds `sway`/`surge` gain sets to `Scheme.new` and `fMain`/`fFrontal` to the `Sim.new` cfg. `fly()` already returns `sim:sensors()`. Translation setpoints go in `loop:setpoints{...}` (`swayPos`, `surgePos`).

- [ ] **Step 1: Write the failing tests** — add to `tests/test_integration.lua`

```lua
t.test("damps a sideways drift back to zero position", function()
  local loop, sim = build(); loop:arm(true)
  loop:setpoints({ altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 })
  fly(loop, sim, 8, function() return 0.1 end)
  sim.swayVel = 1.5; sim.swayPos = 0        -- shove sideways
  fly(loop, sim, 25, function() return 0.1 end)
  t.near(sim:sensors().swayPos, 0, 0.1)     -- returns to station (would fail on runaway/wrong sign)
end)
t.test("translates forward to a commanded position and holds", function()
  local loop, sim = build(); loop:arm(true)
  loop:setpoints({ altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=3 })
  fly(loop, sim, 30, function() return 0.1 end)
  t.near(sim:sensors().surgePos, 3, 0.15)   -- flew forward 3m and held
end)
t.test("leash caps the commanded lead distance", function()
  -- with a leashed setpoint the position error can't exceed maxLead
  local leash = require("fcs.leash")
  local sp = 0
  for _ = 1, 100 do sp = leash.step(sp, 1000, 0, 0.1, 5, 2.0) end
  t.near(sp, 2.0, 1e-9)                      -- pinned at pos(0)+maxLead(2)
end)
```

- [ ] **Step 2: Run.** Expect tolerance failures — the **tuning gate**. Tune `sway`/`surge` gains in `build()` (start `kp≈0.3, kd≈0.5`; more `kd` damps overshoot; add small `ki` only for a steady offset). Keep the sim horizontal thrusts (`fMain`,`fFrontal`,`fPerLat`) reasonable.

- [ ] **Step 3: Achieve green.** Iterate translation gains only until all three pass, and confirm the altitude/attitude/heading acceptance tests still pass unchanged. Record the final gains.

- [ ] **Step 4: Guard-check.** Temporarily flip the sim `SWAY_DIR`, confirm the drift-damping test diverges/fails; restore. Report it.

- [ ] **Step 5: Commit.** `git add tests/test_integration.lua && git commit -m "test(fcs): acceptance — horizontal drift damping, translation, leash cap"`

---

## Self-review

- **Lateral double-duty** (Task 1): sway+yaw combined on one bang-bang duty via orthogonal sign maps — no cross-talk (pinned by test). ✅
- **Surge** (Task 1): main = forward, frontal = reverse/brake, bidirectional. ✅
- **Horizontal plant** (Task 2): sway/surge vel+pos, signs pinned + guard-check. ✅
- **Translation control** (Task 3): position P+I + velocity-sensor damping (mirrors heading, no wrap). ✅
- **Leash** (Task 4): speed-ramped, position-bounded setpoint = the speed cap. ✅
- **Wired** (Task 5) through mixer/runtime; disarmed zeroes all groups. ✅
- **Acceptance** (Task 6): drift damping, translation+hold, leash cap; tuning-only. ✅
- **Type consistency:** `mixLateral(sway,yaw)`/`mixSurge(surge)`/`mix`, `Translate:update(sp,meas,vel,dt)`, `leash.step(...)`, sim `swayVel/surgeVel/swayPos/surgePos`, scheme `.sway/.surge` — consistent.
- **Deferred (not this plan):** world-frame / GPS absolute station-keeping (NAV plan); the safety contract (Plan 4); the yaw-resolution + attitude-margin work (Plan 4 / hardware); real thruster geometry via calibration.

## Follow-on

- **Plan 4** — safety contract (oscillation detector + auto-degrade, envelope limiter, ground-state gating) + the yaw-resolution fix + attitude-margin.
- **NAV plan** — GPS-referenced world-frame absolute position hold + waypoints/autopilot (makes this plan's craft-frame hold drift-free and absolute).
- Then hardware IO backend + sensor calibration + in-game bring-up.
