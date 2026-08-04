# FCS Yaw + Heading Hold Implementation Plan (Plan 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the yaw axis to the EasyHover 2 FCS — the craft holds its commanded heading and re-levels its heading after a yaw disturbance, completing 3-axis rotational control — proven headless in the simulator.

**Architecture:** Extends the merged kernel (Plan 1). The 4 **lateral** thrusters become a new mixer group producing a **yaw couple** (bang-bang, like the lift group's pitch/roll). A dedicated **heading controller** does P+I on the *wrapped* heading error plus rate damping taken **directly from the yaw-rate sensor** (never by differentiating a wrapping angle). The simulator gains a yaw plant; everything plugs into the existing runtime/PWM/backend seam.

**Tech Stack:** Lua 5.1 (CC:Tweaked / CraftOS-PC). Headless tests via `bash tests/run_headless.sh`. No external libraries.

**Base:** branch from `main` at the Plan-1 merge (`668ba53` or later). Everything in Plan 1 is available and green (25 tests).

## Global Constraints

- **Language/runtime:** Lua 5.1 as in CC:Tweaked. No `goto`, no integer `//`, use `math.floor`. No external modules.
- **Testing:** headless via CraftOS-PC, `bash tests/run_headless.sh`. No CC peripheral calls — the backend interface is the only hardware seam; the sim is its only implementation here.
- **No fixed time step, no hardcoded rate.** `dt` is a parameter; every tunable per-second.
- **Angles are radians.** Heading is an angle that **wraps**; all heading error math uses the shortest signed difference. Never differentiate heading across a wrap — yaw-rate damping comes from the sensor (`m.yawRate`).
- **Signs measured, never assumed.** The sim's yaw signs are fixed and pinned by direction tests here; the real lateral-thruster geometry (which thruster yaws which way) is **calibration-bound** in the hardware plan — the mixer exposes a per-thruster `YAW_DIR` map for that.
- **Backend interface (extended):** `backend:sensors()` now also returns `heading` and `yawRate`; `backend:lateralIds()` returns the 4 lateral thruster ids; `backend:setThruster(id,on)` already handles any id.
- DRY, YAGNI (yaw only — sway/surge translation is Plan 3; the collective-lateral **sway** use of these thrusters is NOT built here). TDD. Frequent commits. LF endings.

---

## File structure

```
fcs/
  angle.lua              NEW — wrap(x): shortest signed angle in (-pi, pi]
  frame.lua              MODIFY — add LATERAL ids
  mixer/level_flight.lua MODIFY — add yaw -> lateral-thruster duties (YAW_DIR map)
  control/heading.lua    NEW — heading P+I on wrapped error + rate damping from yawRate
  schemes/level_flight.lua MODIFY — add the yaw/heading loop; return `yaw` in demands
tests/
  sim.lua                MODIFY — yaw plant (heading, yawRate) + lateral thrusters
  test_angle.lua         NEW
  test_yaw_mixer.lua     NEW
  test_sim_yaw.lua       NEW
  test_heading.lua       NEW
  test_integration.lua   MODIFY — heading-hold + yaw-recovery + heading-ramp acceptance
```

Add each new `tests/*.lua` to the suite list in `tests/run_headless.sh`'s generated `startup.lua`.

---

## Task 1: Angle wrap helper

**Files:** Create `fcs/angle.lua`, `tests/test_angle.lua`. Modify `tests/run_headless.sh` (add `tests.test_angle` to the suite list).

**Interfaces:** Produces `angle.wrap(x) -> number` — the value of `x` folded into `(-math.pi, math.pi]`.

- [ ] **Step 1: Write the failing tests** — `tests/test_angle.lua`

```lua
local t = require("tests.framework")
local angle = require("fcs.angle")
local PI = math.pi
t.test("wrap leaves small angles unchanged", function() t.near(angle.wrap(0.3), 0.3, 1e-9) end)
t.test("wrap folds just over +pi to just over -pi", function()
  t.near(angle.wrap(PI + 0.1), -PI + 0.1, 1e-9)
end)
t.test("wrap folds a large negative angle", function()
  t.near(angle.wrap(-3 * PI + 0.2), 0.2 - PI, 1e-6)
end)
t.test("shortest error across the wrap is small", function()
  -- heading 0.05 rad, setpoint at -0.05 rad expressed as ~2pi-0.05
  t.near(angle.wrap((2 * PI - 0.05) - 0.05), -0.1, 1e-6)
end)
```

- [ ] **Step 2: Run — verify fail.** `bash tests/run_headless.sh` → FAIL (`fcs.angle` not found). Also add `"tests.test_angle"` to the `suites` list in the `startup.lua` heredoc inside `tests/run_headless.sh` so it runs.

- [ ] **Step 3: Implement** — `fcs/angle.lua`

```lua
local M = {}
function M.wrap(x)
  local twoPi = 2 * math.pi
  x = x % twoPi                 -- [0, 2pi)
  if x > math.pi then x = x - twoPi end
  return x
end
return M
```

- [ ] **Step 4: Run — verify pass.** `bash tests/run_headless.sh` → PASS.

- [ ] **Step 5: Commit.** `git add fcs/angle.lua tests/test_angle.lua tests/run_headless.sh && git commit -m "feat(angle): shortest signed angle wrap"`

---

## Task 2: Lateral group + yaw mixer

**Files:** Modify `fcs/frame.lua`, `fcs/mixer/level_flight.lua`. Create `tests/test_yaw_mixer.lua`. Modify `tests/run_headless.sh` (add `tests.test_yaw_mixer`).

**Interfaces:**
- `frame.LATERAL = {"YFL","YFR","YRL","YRR"}` (yaw-lateral, four corners).
- `Mixer:mixYaw(yaw) -> {[id]=duty}` for the four lateral ids. A per-thruster `YAW_DIR` map (`YFL=1, YRR=1, YFR=-1, YRL=-1`) gives each thruster its yaw-couple sign; `duty = clamp(YAW_DIR[id] * yaw, 0, 1)`. Positive `yaw` (nose-right) fires the `+1` thrusters, the `-1` thrusters clamp to 0; negative `yaw` does the reverse. (Bang-bang thrusters are one-directional, so a signed yaw command lights the correct opposing pair.)

- [ ] **Step 1: Write the failing tests** — `tests/test_yaw_mixer.lua`

```lua
local t = require("tests.framework")
local Mixer = require("fcs.mixer.level_flight")
t.test("positive yaw fires the +dir pair, zeroes the others", function()
  local d = Mixer.new():mixYaw(0.4)
  t.near(d.YFL, 0.4, 1e-9); t.near(d.YRR, 0.4, 1e-9)
  t.near(d.YFR, 0, 1e-9);   t.near(d.YRL, 0, 1e-9)
end)
t.test("negative yaw fires the -dir pair", function()
  local d = Mixer.new():mixYaw(-0.4)
  t.near(d.YFR, 0.4, 1e-9); t.near(d.YRL, 0.4, 1e-9)
  t.near(d.YFL, 0, 1e-9);   t.near(d.YRR, 0, 1e-9)
end)
t.test("yaw duty clamps to 1", function()
  t.near(Mixer.new():mixYaw(1.5).YFL, 1, 1e-9)
end)
```

- [ ] **Step 2: Run — verify fail** (method missing). Add `"tests.test_yaw_mixer"` to the suite list.

- [ ] **Step 3: Implement.** `fcs/frame.lua`: add `LATERAL = { "YFL", "YFR", "YRL", "YRR" }` to the returned table (keep `LIFT`). In `fcs/mixer/level_flight.lua` add (reuse the existing local `clamp`):

```lua
local YAW_DIR = { YFL = 1, YFR = -1, YRL = -1, YRR = 1 }
function Mixer:mixYaw(yaw)
  local out = {}
  for id, dir in pairs(YAW_DIR) do out[id] = clamp(dir * (yaw or 0)) end
  return out
end
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit.** `git add fcs/frame.lua fcs/mixer/level_flight.lua tests/test_yaw_mixer.lua tests/run_headless.sh && git commit -m "feat(mixer): yaw couple -> lateral thruster duties"`

---

## Task 3: Sim yaw plant

**Files:** Modify `tests/sim.lua`. Create `tests/test_sim_yaw.lua`. Modify `tests/run_headless.sh` (add `tests.test_sim_yaw`).

**Interfaces:** `Sim` now tracks `heading` and `yawRate`; `sim:step` adds a yaw moment `= Σ YAW_DIR[id]·fPerLat·(on?)` over the lateral thrusters, `yawAccel = yawMoment / yawInertia`. `sim:sensors()` adds `heading` and `yawRate`. `sim:lateralIds()` returns `frame.LATERAL`. Config gains: `fPerLat` (default 8), `yawInertia` (default 2). Convention: `+yaw` = nose-right; the sim's `YAW_DIR` must match the mixer's (`YFL=1,YRR=1,YFR=-1,YRL=-1`).

- [ ] **Step 1: Write the failing tests** — `tests/test_sim_yaw.lua`

```lua
local t = require("tests.framework")
local Sim = require("tests.sim")
local function cfg() return { mass=4, g=10, fPer=15, inertia=2, armX=1, armZ=1, fPerLat=8, yawInertia=2 } end
t.test("firing the +yaw pair yaws nose-right (yawRate > 0)", function()
  local s = Sim.new(cfg())
  s:setThruster("YFL", true); s:setThruster("YRR", true)
  s:step(0.1)
  t.truthy(s:sensors().yawRate > 0)
end)
t.test("firing the -yaw pair yaws nose-left (yawRate < 0)", function()
  local s = Sim.new(cfg())
  s:setThruster("YFR", true); s:setThruster("YRL", true)
  s:step(0.1)
  t.truthy(s:sensors().yawRate < 0)
end)
t.test("heading integrates yawRate", function()
  local s = Sim.new(cfg())
  s:setThruster("YFL", true); s:setThruster("YRR", true)
  s:step(0.1); s:step(0.1)
  t.truthy(s:sensors().heading > 0)
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_sim_yaw"` to the suite list.

- [ ] **Step 3: Implement** — in `tests/sim.lua`:
  - `local frame = require("fcs.frame")` already present. Add a yaw-dir table matching the mixer: `local YAW_DIR = { YFL = 1, YFR = -1, YRL = -1, YRR = 1 }`.
  - In `Sim.new`: initialise `self.heading, self.yawRate = 0, 0`; and `for _, id in ipairs(frame.LATERAL) do self.on[id] = false end`.
  - Add `function Sim:lateralIds() return frame.LATERAL end`.
  - In `Sim:step(dt)`, after the existing pitch/roll integration, add:

```lua
local ym = 0
for _, id in ipairs(frame.LATERAL) do
  if self.on[id] then ym = ym + YAW_DIR[id] * self.cfg.fPerLat end
end
self.yawRate = self.yawRate + (ym / self.cfg.yawInertia) * dt
self.heading = self.heading + self.yawRate * dt
```

  - In `Sim:sensors()` add `heading = self.heading, yawRate = self.yawRate` to the returned table.

- [ ] **Step 4: Run — verify pass.** Sanity: temporarily flip the sim `YAW_DIR` and confirm the two direction tests fail, then restore (pins the yaw sign against physics, not against the controller).

- [ ] **Step 5: Commit.** `git add tests/sim.lua tests/test_sim_yaw.lua tests/run_headless.sh && git commit -m "test(sim): yaw plant (heading, yawRate) from lateral thrusters, signs pinned"`

---

## Task 4: Heading controller

**Files:** Create `fcs/control/heading.lua`, `tests/test_heading.lua`. Modify `tests/run_headless.sh` (add `tests.test_heading`).

**Interfaces:** `Heading.new(cfg) -> h`; `h:update(headingSp, headingMeas, yawRate, dt) -> yawDemand`; `h:reset()`. `cfg = {kp, ki, kd, iMin, iMax, dtMax}`. Law: `err = angle.wrap(headingSp - headingMeas)`; P+I on `err` (integrate only when `dt`-usable, clamp `i`); **damping is `-kd·yawRate`** (rate feedback from the sensor, not a differentiated heading). Output `= kp·err + i − kd·yawRate`.

- [ ] **Step 1: Write the failing tests** — `tests/test_heading.lua`

```lua
local t = require("tests.framework")
local Heading = require("fcs.control.heading")
local PI = math.pi
t.test("commands a right turn for a positive wrapped error", function()
  local h = Heading.new({ kp = 1, ki = 0, kd = 0 })
  t.near(h:update(0.5, 0.0, 0.0, 0.1), 0.5, 1e-9)
end)
t.test("takes the short way across the wrap", function()
  local h = Heading.new({ kp = 1, ki = 0, kd = 0 })
  -- setpoint just below +pi wrap from measurement just above -pi: short error is negative
  local out = h:update(-PI + 0.05, PI - 0.05, 0.0, 0.1)
  t.truthy(out < 0)                       -- turns the short way (left), not +2pi right
end)
t.test("damps proportionally to yaw rate", function()
  local h = Heading.new({ kp = 0, ki = 0, kd = 0.5 })
  t.near(h:update(0, 0, 2.0, 0.1), -1.0, 1e-9)   -- -kd*yawRate
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_heading"` to the suite list.

- [ ] **Step 3: Implement** — `fcs/control/heading.lua`

```lua
local angle = require("fcs.angle")
local H = {}
H.__index = H
function H.new(cfg)
  local self = setmetatable({}, H)
  self.kp = cfg.kp or 0; self.ki = cfg.ki or 0; self.kd = cfg.kd or 0
  self.iMin = cfg.iMin or -math.huge; self.iMax = cfg.iMax or math.huge
  self.dtMax = cfg.dtMax or 0.5
  self:reset(); return self
end
function H:reset() self.i = 0 end
function H:update(sp, meas, yawRate, dt)
  local err = angle.wrap(sp - meas)
  if dt > 0 and dt <= self.dtMax then
    self.i = self.i + self.ki * err * dt
    if self.i > self.iMax then self.i = self.iMax elseif self.i < self.iMin then self.i = self.iMin end
  end
  return self.kp * err + self.i - self.kd * (yawRate or 0)
end
return H
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit.** `git add fcs/control/heading.lua tests/test_heading.lua tests/run_headless.sh && git commit -m "feat(heading): P+I on wrapped error + yaw-rate damping"`

---

## Task 5: Wire yaw into the scheme and the mixer output

**Files:** Modify `fcs/schemes/level_flight.lua`, `fcs/mixer/level_flight.lua`, `fcs/runtime/loop.lua`. Add a scheme unit test to `tests/test_integration.lua`.

**Interfaces:**
- `Scheme.new(cfg)` also builds `self.heading = Heading.new(cfg.yaw or {})`.
- `scheme:update(sp, m, dt)` also returns `yaw = self.heading:update(sp.heading or 0, m.heading or 0, m.yawRate or 0, dt)`; `scheme:reset()` also resets it.
- `Mixer:mix(d)` now returns lift duties **and** the yaw/lateral duties merged into one table (so the runtime writes them together). Implement by merging `mixYaw(d.yaw)` into the returned table.
- `loop:cycle` is unchanged in shape — it already does `mixer:mix(demands)` → `pwm:apply(duties, dt)`; the duties table now simply also carries the four lateral ids. On the **disarmed** path, also command the lateral ids to 0 (extend the `zeros` table to include `frame.LATERAL`).

- [ ] **Step 1: Write the failing test** — add to `tests/test_integration.lua`

```lua
local Heading = require("fcs.control.heading")
t.test("scheme emits a yaw demand toward the heading setpoint", function()
  local sc = Scheme.new({ hoverDuty = 0.66,
    alt = { kp = 0.04, ki = 0.02, kd = 0.30, tauD = 0.2, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    roll  = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    yaw   = { kp = 0.5, ki = 0, kd = 0.2 } })
  local d = sc:update({ altitude = 10, pitch = 0, roll = 0, heading = 0.4 },
                      { altitude = 10, vSpeed = 0, pitch = 0, pitchRate = 0, roll = 0, rollRate = 0,
                        heading = 0.0, yawRate = 0.0 }, 0.1)
  t.truthy(d.yaw > 0)                     -- +0.4 heading error -> yaw right
end)
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement.**
  - `fcs/schemes/level_flight.lua`: `local Heading = require("fcs.control.heading")`; in `new`, `self.headingPid = Heading.new(cfg.yaw or {})`; in `reset`, add `self.headingPid:reset()`; in `update`, add `yaw = self.headingPid:update(sp.heading or 0, m.heading or 0, m.yawRate or 0, dt)` to the returned table.
  - `fcs/mixer/level_flight.lua`: at the end of `Mixer:mix`, merge yaw duties in:

```lua
function Mixer:mix(d)
  local h, p, r = d.heave or 0, d.pitch or 0, d.roll or 0
  local out = {
    FL = clamp(h + p + r), FR = clamp(h + p - r),
    RL = clamp(h - p + r), RR = clamp(h - p - r),
  }
  for id, duty in pairs(self:mixYaw(d.yaw)) do out[id] = duty end
  return out
end
```

  - `fcs/runtime/loop.lua`: in the disarmed branch, build `zeros` over **both** groups: `for _, id in ipairs(frame.LIFT) do zeros[id] = 0 end` then `for _, id in ipairs(frame.LATERAL) do zeros[id] = 0 end`.

- [ ] **Step 4: Run — verify pass** (26 tests: 25 prior + this one).

- [ ] **Step 5: Commit.** `git add fcs/schemes/level_flight.lua fcs/mixer/level_flight.lua fcs/runtime/loop.lua tests/test_integration.lua && git commit -m "feat(scheme): heading loop wired through mixer + runtime"`

---

## Task 6: Acceptance — heading hold + yaw recovery + heading ramp

**Files:** Modify `tests/test_integration.lua`. (Tuning task — like Task 11/12 in Plan 1: adjust the `yaw` gains in `build()` until green; do NOT weaken assertions or change module logic.)

**Interfaces:** Consumes the existing `build()` / `fly()` helpers. `build()` must add a `yaw` gain set to the `Scheme.new` config and `Sim.new` must get `fPerLat`/`yawInertia` (add to the sim cfg in `build()`). `fly()` reads `sim:sensors().heading`.

- [ ] **Step 1: Write the failing tests** — add to `tests/test_integration.lua`

```lua
t.test("holds commanded heading and converges from a yaw disturbance", function()
  local loop, sim = build(); loop:arm(true)
  loop:setpoints({ altitude = 10, pitch = 0, roll = 0, heading = 0.0 })
  fly(loop, sim, 10, function() return 0.1 end)   -- settle
  sim.heading = 0.6; sim.yawRate = 0               -- inject a heading disturbance (~34 deg)
  fly(loop, sim, 25, function() return 0.1 end)
  t.near(sim:sensors().heading, 0.0, 0.05)         -- re-levels heading (would fail on a limit cycle / wrong sign)
end)
t.test("captures and holds a new commanded heading", function()
  local loop, sim = build(); loop:arm(true)
  loop:setpoints({ altitude = 10, pitch = 0, roll = 0, heading = 0.8 })
  fly(loop, sim, 30, function() return 0.1 end)
  t.near(sim:sensors().heading, 0.8, 0.05)         -- flew to the commanded heading and held
end)
```

- [ ] **Step 2: Run.** Expect initial tolerance failures — the **tuning gate**. Tune the `yaw` gains in `build()` (start `kp≈0.5, kd≈0.2`; add `ki` small only if a steady bias remains). More `kd` damps a yaw limit cycle, exactly as it did for pitch/roll.

- [ ] **Step 3: Achieve green.** Iterate `yaw` gains only until both tests pass. Confirm the altitude + attitude acceptance tests still pass unchanged. Record the final yaw gains.

- [ ] **Step 4: Guard-check the sign.** Temporarily flip the sim `YAW_DIR` and confirm the yaw-recovery test now fails (diverges); restore. Report it.

- [ ] **Step 5: Commit + push.**

```bash
git add tests/test_integration.lua
git commit -m "test(fcs): acceptance — heading hold, yaw recovery, heading capture"
```

---

## Self-review

- **Angle wrap** (Task 1) → heading error never spins the long way. ✅
- **Yaw actuation** (Tasks 2–3): mixer yaw couple + sim yaw plant, signs pinned by direction tests and a guard-check flip. ✅
- **Rate damping from the sensor** (Task 4) → no differentiating a wrapping angle. ✅
- **Wired end-to-end** (Task 5) through the existing mixer/runtime/PWM/backend seam; disarmed path zeroes the lateral group too. ✅
- **Acceptance** (Task 6): heading hold, disturbance recovery to level, heading capture; tuning-only, assertions not weakened. ✅
- **Type consistency:** `angle.wrap`, `Mixer:mixYaw`/`:mix`, `Heading:update(sp,meas,yawRate,dt)`, `scheme:update(...).yaw`, sim `heading`/`yawRate`/`lateralIds` — consistent across tasks.
- **Deferred (not this plan):** collective-lateral **sway** + surge translation + the leash (Plan 3); oscillation detector / envelope / ground gating (Plan 4); real lateral-thruster geometry via calibration (hardware plan). The `YAW_DIR` map is the calibration seam.

## Follow-on

- **Plan 3** — horizontal translation + leashed position hold (sway/surge, lateral+main+frontal thrusters, horizontal plant).
- **Plan 4** — the safety contract (oscillation detector + auto-degrade, envelope limiter, ground-state gating).
- Then hardware IO backend + sensor calibration + in-game bring-up.
