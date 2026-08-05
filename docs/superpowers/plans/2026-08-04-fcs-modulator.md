# FCS Sigma-Delta Modulator Implementation Plan (Plan 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tighten the yaw / sway / surge hold by driving the non-lift thrusters with a **sigma-delta (pulse-density) modulator** instead of the coarse synchronized PWM — recovering fine resolution for actuators that idle at zero (design §17 #8). Proven headless by holding those axes on a *harder* plant than the PWM floor could manage.

**Architecture:** Extends the merged FCS (Plans 1–4). Adds `fcs/actuate/sigma_delta.lua` — a per-thruster first-order sigma-delta modulator (accumulate `duty·dt`, fire a full cycle when a cycle's worth of on-time is banked). The runtime routes **lift** thruster ids to the existing synchronized PWM (unchanged — its all-together pulsing kills attitude moment-ripple, which sigma-delta would reintroduce) and **lateral/main/frontal** ids to the sigma-delta bank. Pluggable and backward-compatible: a `Loop` built without a sigma-delta modulator behaves exactly as before.

**Tech Stack:** Lua 5.1 (CC:Tweaked / CraftOS-PC). Headless via `bash tests/run_headless.sh`. No external libraries.

**Base:** branch from `main` at the Plan-4 merge (`72b4cf3` or later). 74 tests green.

## Global Constraints

- Lua 5.1 (no `goto`, no `//`, `math.floor`, no external modules). **No fixed time step** — the modulator must be dt-driven (accumulate on-time in seconds). TDD; targeted commits; LF.
- The lift group's synchronized PWM is NOT changed. Only non-lift (lateral YFL/YFR/YRL/YRR, MAIN, frontal FRL/FRR) move to sigma-delta.
- Backward compat: `Loop` with no `sd` modulator routes everything to the PWM as today (all prior tests that construct a bare Loop stay valid).
- YAGNI: first-order sigma-delta only. No dithering, no higher-order loops, no per-axis tuning of the modulator itself.

---

## File structure

```
fcs/
  actuate/sigma_delta.lua  NEW — per-thruster PDM: apply(duties, dt), write-on-change
  runtime/loop.lua         MODIFY — route lift->pwm, non-lift->sd (when a sd modulator is provided)
tests/
  test_sigma_delta.lua     NEW
  test_integration.lua     MODIFY — build() wires an sd bank for non-lift; add a fine-hold acceptance
```

Add `tests/test_sigma_delta.lua` to the suite list in `tests/run_headless.sh`.

---

## Task 1: Sigma-delta modulator

**Files:** Create `fcs/actuate/sigma_delta.lua`, `tests/test_sigma_delta.lua`. Modify `tests/run_headless.sh`.

**Interfaces:** `SigmaDelta.new({backend}) -> sd`; `sd:apply(duties, dt)` where `duties = {[id]=0..1}`. Per thruster: `acc[id] = acc[id] + duty*dt`; if `acc[id] >= dt` then output **on** for this cycle and `acc[id] = acc[id] - dt`, else **off**. Calls `backend:setThruster(id, on)` **only on state change** (write-on-change). `sd:state(id) -> bool`. Over many cycles the average on-fraction of each thruster equals its `duty`.

- [ ] **Step 1: Write the failing tests** — `tests/test_sigma_delta.lua`

```lua
local t = require("tests.framework")
local SigmaDelta = require("fcs.actuate.sigma_delta")
local function recBackend()
  local b = { writes = 0, on = {} }
  function b:setThruster(id, s) self.writes = self.writes + 1; self.on[id] = s end
  return b
end
t.test("duty 1 always on, duty 0 always off", function()
  local b = recBackend(); local sd = SigmaDelta.new({ backend = b })
  for _ = 1, 20 do sd:apply({ a = 1.0, z = 0.0 }, 0.1) end
  t.truthy(sd:state("a") == true); t.truthy(sd:state("z") == false)
end)
t.test("average on-fraction tracks a fractional duty", function()
  local b = recBackend(); local sd = SigmaDelta.new({ backend = b })
  local onCount, N = 0, 400
  for _ = 1, N do sd:apply({ a = 0.25 }, 0.1); if sd:state("a") then onCount = onCount + 1 end end
  t.near(onCount / N, 0.25, 0.02)              -- density matches duty
end)
t.test("resolves a small duty the coarse PWM would quantise away", function()
  local b = recBackend(); local sd = SigmaDelta.new({ backend = b })
  local onCount, N = 0, 1000
  for _ = 1, N do sd:apply({ a = 0.05 }, 0.1); if sd:state("a") then onCount = onCount + 1 end end
  t.near(onCount / N, 0.05, 0.02)              -- ~5% density, not 0 and not 33%
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_sigma_delta"` to the suites list.

- [ ] **Step 3: Implement** — `fcs/actuate/sigma_delta.lua`

```lua
local SD = {}
SD.__index = SD
function SD.new(cfg)
  return setmetatable({ backend = cfg.backend, acc = {}, on = {} }, SD)
end
function SD:state(id) return self.on[id] == true end
function SD:apply(duties, dt)
  for id, duty in pairs(duties) do
    local a = (self.acc[id] or 0) + (duty or 0) * dt
    local want
    if dt > 0 and a >= dt then want = true; a = a - dt else want = false end
    self.acc[id] = a
    if self.on[id] ~= want then
      self.on[id] = want
      self.backend:setThruster(id, want)
    end
  end
end
return SD
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit.** `git add fcs/actuate/sigma_delta.lua tests/test_sigma_delta.lua tests/run_headless.sh && git commit -m "feat(actuate): first-order sigma-delta (pulse-density) modulator"`

---

## Task 2: Route non-lift thrusters through sigma-delta

**Files:** Modify `fcs/runtime/loop.lua`. Modify `tests/test_integration.lua` (`build()` wires an sd bank; keep all prior tests green).

**Interfaces:** `Loop.new` cfg gains an optional `sd` (a `SigmaDelta` instance). When present, `cycle` splits the mixer's duty table: ids in `frame.LIFT` go to `self.pwm:apply(...)` (synchronized, unchanged); all other ids go to `self.sd:apply(...)`. When `sd` is absent, everything goes to `self.pwm` exactly as today (backward compatible). The **disarmed** path routes the zero duties the same way (lift zeros → pwm, non-lift zeros → sd). Build the `isLift` set once from `frame.LIFT`.

- [ ] **Step 1: Write the failing test** — add to `tests/test_integration.lua`

```lua
t.test("runtime routes lift to PWM and non-lift to sigma-delta", function()
  local SigmaDelta = require("fcs.actuate.sigma_delta")
  local Pwm = require("fcs.actuate.pwm")
  local Mixer = require("fcs.mixer.level_flight")
  local Sim = require("tests.sim")
  local Scheme = require("fcs.schemes.level_flight")
  local Loop = require("fcs.runtime.loop")
  local sim = Sim.new({ mass=4, g=10, fPer=15, inertia=2, armX=1, armZ=1,
    fPerLat=8, yawInertia=8, fMain=20, fFrontal=10 })
  local sc = Scheme.new({ hoverDuty=0.66,
    alt={kp=0.04,ki=0.02,kd=0.30,tauD=0.2,iMax=0.3,iMin=-0.3},
    pitch={kp=0.3,ki=0,kd=0.4,tauD=0.2}, roll={kp=0.3,ki=0,kd=0.4,tauD=0.2},
    yaw={kp=0.5,ki=0,kd=0.2}, sway={kp=0.3,ki=0,kd=0.5}, surge={kp=0.3,ki=0,kd=0.5} })
  local loop = Loop.new({ scheme=sc, mixer=Mixer.new(),
    pwm=Pwm.new({ period=0.3, backend=sim }),
    sd=SigmaDelta.new({ backend=sim }), backend=sim, dtMax=0.5 })
  loop:arm(true); loop:setpoints({ altitude=10, pitch=0, roll=0, heading=0.5, swayPos=0, surgePos=0 })
  for _ = 1, 60 do loop:cycle(0.1); sim:step(0.1) end
  t.near(sim:sensors().heading, 0.5, 0.05)      -- yaw still reaches heading via sigma-delta
end)
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement** in `fcs/runtime/loop.lua`: `require("fcs.frame")` (already there); build `self.isLift = {}` from `frame.LIFT` in `new`; store `self.sd = cfg.sd`. In `cycle`, replace the single `self.pwm:apply(duties, dt)` (both armed and disarmed) with a router: if `self.sd`, partition the duty table into lift vs non-lift and call `pwm:apply` / `sd:apply` respectively; else `pwm:apply(duties, dt)` as before. Then update the `build()` helper in `tests/test_integration.lua` to pass a `sd = SigmaDelta.new({ backend = sim })` into `Loop.new`. **All prior acceptance tests must stay green** — if the modulator swap shifts heading/horizontal convergence slightly, retune only the affected gains in `build()` (tuning, not weakening assertions).

- [ ] **Step 4: Run — verify pass** (the new routing test + all prior, now under sigma-delta for non-lift).

- [ ] **Step 5: Commit.** `git add fcs/runtime/loop.lua tests/test_integration.lua && git commit -m "feat(runtime): route non-lift thrusters through sigma-delta"`

---

## Task 3: Acceptance — the floor is gone (fine hold on a hard plant)

**Files:** Modify `tests/test_integration.lua`.

**Interfaces:** Consumes `build()`/`fly()`. The point: prove sigma-delta holds yaw (and sway) on a plant that the coarse PWM could NOT hold tightly — i.e. *without* the `yawInertia`/`fPerLat` crutches Plans 2–3 needed. Use a local sim/loop with the **hard** params (`yawInertia = 2`, `fPerLat = 8`) and a tight tolerance.

- [ ] **Step 1: Write the failing tests** — add to `tests/test_integration.lua`

```lua
t.test("sigma-delta holds heading tightly on the hard (un-crutched) plant", function()
  local SigmaDelta = require("fcs.actuate.sigma_delta")
  local Pwm = require("fcs.actuate.pwm")
  local Mixer = require("fcs.mixer.level_flight")
  local Sim = require("tests.sim")
  local Scheme = require("fcs.schemes.level_flight")
  local Loop = require("fcs.runtime.loop")
  local sim = Sim.new({ mass=4, g=10, fPer=15, inertia=2, armX=1, armZ=1,
    fPerLat=8, yawInertia=2, fMain=20, fFrontal=10 })   -- HARD: yawInertia 2 (Plan 2 needed 8)
  local sc = Scheme.new({ hoverDuty=0.66,
    alt={kp=0.04,ki=0.02,kd=0.30,tauD=0.2,iMax=0.3,iMin=-0.3},
    pitch={kp=0.3,ki=0,kd=0.4,tauD=0.2}, roll={kp=0.3,ki=0,kd=0.4,tauD=0.2},
    yaw={kp=0.5,ki=0,kd=0.2}, sway={kp=0.3,ki=0,kd=0.5}, surge={kp=0.3,ki=0,kd=0.5} })
  local loop = Loop.new({ scheme=sc, mixer=Mixer.new(),
    pwm=Pwm.new({ period=0.3, backend=sim }),
    sd=SigmaDelta.new({ backend=sim }), backend=sim, dtMax=0.5 })
  loop:arm(true); loop:setpoints({ altitude=10, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 })
  local function flyLocal(sec) local tt=0; while tt<sec do loop:cycle(0.1); sim:step(0.1); tt=tt+0.1 end end
  flyLocal(8); sim.heading = 0.5; sim.yawRate = 0        -- disturb
  flyLocal(30)
  t.near(sim:sensors().heading, 0, 0.05)                 -- holds tight where coarse PWM floored ~0.12 rad
end)
```

- [ ] **Step 2: Run.** If it doesn't converge tightly, the fix is genuine tuning (adjust the `yaw` gains for the sigma-delta-actuated hard plant) — NOT weakening the `0.05` tolerance. If the sigma-delta modulator genuinely cannot beat the floor here, STOP and report **BLOCKED** with the residual + evidence (that would send us to the bias-baseline alternative instead).

- [ ] **Step 3: Achieve green + confirm no regression** (all prior tests, now under sigma-delta, stay green). Record the residual achieved vs the old ~0.12 rad PWM floor.

- [ ] **Step 4: Commit.** `git add tests/test_integration.lua && git commit -m "test(fcs): sigma-delta holds heading tight on the hard plant (floor gone)"`

---

## Self-review

- **Sigma-delta** (Task 1): dt-driven pulse-density, average tracks duty even at 0.05, write-on-change. ✅
- **Routing** (Task 2): lift keeps synchronized PWM (no moment-ripple change), non-lift gets fine resolution; backward-compatible when no `sd`. ✅
- **Acceptance** (Task 3): tight heading hold on the *hard* plant the PWM floor couldn't manage — the §17 #8 fix, demonstrated. ✅
- **Type consistency:** `SigmaDelta.new({backend})`, `sd:apply(duties,dt)`/`sd:state(id)` mirror `Pwm`; `Loop.new{... sd=}`. Consistent.
- **Deferred/alt:** if sigma-delta underperforms, the bias-baseline approach (idle opposing pairs at a small standing thrust so yaw/lateral modulate around a nonzero point) is the fallback — noted, not built.

## Follow-on

- **Hardware IO + sensor calibration + in-game bring-up** — real backend, sign-measuring calibration, first flight (measure real loop rate, heave bob, and confirm the floor fix on the actual craft).
- **Comms + UI** — decoupled telemetry/command + cockpit (reported-state only).
- **NAV/GPS** — world-frame absolute position hold + autopilot.
