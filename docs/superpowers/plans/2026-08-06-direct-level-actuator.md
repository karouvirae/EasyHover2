# Direct 16-Level Thruster Actuator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Fresh-session context:** read `docs/superpowers/specs/2026-08-06-direct-level-actuator-design.md` first — especially §1 (why). TL;DR: on the real craft each `setPower` write costs ~50 ms (mainThread); the bang-bang PWM + sigma-delta modulators toggle 2–7 thrusters *every* cycle, collapsing the flight control loop from ~18 Hz (idle) to ~5.7 Hz (flying), which makes attitude uncontrollable. Fix: drive the thrusters' 16 native analog levels directly and **write only when a thruster's quantized level changes** — a steady hover then holds steady levels → almost no writes → the loop keeps ~18 Hz. Rollback point: tag `pre-level-actuator` (commit `bd4e9a5`).

**Goal:** Replace time-domain PWM/sigma-delta actuation in the flight runner with a direct 16-level `setPower` actuator that writes only on level change, restoring the control-loop rate during flight.

**Architecture:** New `fcs/actuate/level.lua` (same interface as `fcs/actuate/pwm.lua`), a new `Backend:setThrusterLevel(id, level)`, and a one-spot rewire of `tools/hover_test.lua`'s `buildLoop` to use the level actuator for all thrusters (`sd = nil`). No control-math, profile, safety, or `Loop` changes. PWM/sigma-delta stay for the sim/integration tests.

**Tech Stack:** CC:Tweaked Lua 5.1, CraftOS-PC headless harness, existing `tests/framework.lua`.

## Global Constraints

- **Lua 5.1** — no goto, no integer division, no `#` on nil. `round(x) = math.floor(x + 0.5)`.
- **Wrapped peripherals take NO `self`** — write `p.setPower(level)`, never `p:setPower(level)`.
- **Prints ASCII-only. No external deps.** Test API is only `t.test/t.eq/t.near/t.truthy`.
- **Tests run via** `bash tests/run_headless.sh` (runs ALL suites; no single-test runner). Register new suites in that script's `startup.lua` `suites` table.
- **Do NOT change** `fcs/runtime/loop.lua`, the control math, `fcs/tuning.lua`, the profile, or the safety guards. **Do NOT touch** `fcs/actuate/pwm.lua` or `fcs/actuate/sigma_delta.lua` (the sim/integration suites depend on them and must stay green).
- **Level actuator interface must match `pwm.lua`:** `Level.new(cfg)`, `:apply(duties, dt)`, `:state(id)` — so it drops into the `Loop`'s `pwm` slot with `sd = nil`.

## File Structure

- Create `fcs/actuate/level.lua` — the level-quantizing actuator (Task 1).
- Create `tests/test_level.lua` (Task 1).
- Modify `fcs/io/backend.lua` — add `setThrusterLevel` (Task 2).
- Modify `tests/test_backend.lua` — cover it (Task 2).
- Modify `tools/hover_test.lua` — rewire `buildLoop` (Task 3).
- Modify `tools/install_hovertest.lua` — fetch the new file (Task 3).
- Modify `tests/run_headless.sh` — register `test_level` (Task 1).

---

### Task 1: `fcs/actuate/level.lua` — direct 16-level actuator

**Files:**
- Create: `fcs/actuate/level.lua`
- Test: `tests/test_level.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: a backend exposing `setThrusterLevel(id, level)` (Task 2 adds the real one; the test uses a fake).
- Produces: `Level.new(cfg)` (`cfg.backend`, `cfg.steps` default 15); `Level:apply(duties, dt)` (dt ignored) — quantizes each duty to `round(duty*steps)` clamped to `[0, steps]` and calls `backend:setThrusterLevel(id, level)` ONLY when that id's level changed; `Level:state(id)` → last level or 0.

- [ ] **Step 1: Write the failing test** — create `tests/test_level.lua`:

```lua
local t = require("tests.framework")
local Level = require("fcs.actuate.level")

local function fakeBackend()
  local b = { writes = 0, level = {} }
  function b:setThrusterLevel(id, lvl) self.writes = self.writes + 1; self.level[id] = lvl end
  return b
end

t.test("quantizes duty to 0..steps levels (round half up)", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 0, FR = 1, RL = 0.5, RR = 0.2 }, 0)
  t.eq(b.level.FL, 0); t.eq(b.level.FR, 15); t.eq(b.level.RL, 8); t.eq(b.level.RR, 3)
end)
t.test("clamps out-of-range duty", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ H = 1.2, L = -0.1 }, 0)
  t.eq(b.level.H, 15); t.eq(b.level.L, 0)
end)
t.test("writes only when the quantized level changes", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 0.5 }, 0);  t.eq(b.writes, 1)   -- level 8, write #1
  a:apply({ FL = 0.5 }, 0);  t.eq(b.writes, 1)   -- same -> no write
  a:apply({ FL = 0.52 }, 0); t.eq(b.writes, 1)   -- 7.8 -> round 8 -> still 8 -> no write
  a:apply({ FL = 0.6 }, 0);  t.eq(b.writes, 2)   -- 9.0 -> level 9 -> write #2
end)
t.test("state returns the last written level, 0 if unseen", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 1 }, 0)
  t.eq(a:state("FL"), 15); t.eq(a:state("XX"), 0)
end)
```

- [ ] **Step 2: Register the suite** — in `tests/run_headless.sh`, append `"tests.test_level"` to the `suites` table in the `startup.lua` heredoc (after the last entry, currently `"tests.test_scheme_heave"`).

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — `SUITE LOAD FAILURES` for `tests.test_level` (module not found).

- [ ] **Step 4: Write the implementation** — create `fcs/actuate/level.lua`:

```lua
-- Direct 16-level thruster actuator. Writes setPower(0..15) ONLY when a thruster's quantized
-- level changes -> a steady hover holds steady levels -> almost no writes -> the control loop
-- keeps its ~18Hz rate instead of collapsing to ~5Hz under time-domain PWM/sigma-delta toggling
-- (each setPower write costs ~50ms mainThread). Same interface as fcs/actuate/pwm.lua.
local Level = {}
Level.__index = Level

function Level.new(cfg)
  return setmetatable({ backend = cfg.backend, steps = cfg.steps or 15, last = {} }, Level)
end

function Level:state(id) return self.last[id] or 0 end

local function quantize(v, steps)
  v = math.floor(v + 0.5)
  if v < 0 then return 0 elseif v > steps then return steps else return v end
end

function Level:apply(duties, dt)
  for id, duty in pairs(duties) do
    local level = quantize((duty or 0) * self.steps, self.steps)
    if self.last[id] ~= level then
      self.last[id] = level
      self.backend:setThrusterLevel(id, level)
    end
  end
end

return Level
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — all suites pass including `tests.test_level`.

- [ ] **Step 6: Commit**

```bash
git add fcs/actuate/level.lua tests/test_level.lua tests/run_headless.sh
git commit -m "feat(actuate): direct 16-level thruster actuator (write-on-level-change)"
```

---

### Task 2: `Backend:setThrusterLevel(id, level)`

**Files:**
- Modify: `fcs/io/backend.lua`
- Test: `tests/test_backend.lua`

**Interfaces:**
- Consumes: existing `Backend:_periph(name)` and `self.config.thrusters`.
- Produces: `Backend:setThrusterLevel(id, level)` — writes `setPower(level)` (0..15) to the bound peripheral; unbound id is a no-op. The real backend the Task 1 actuator will call in flight.

- [ ] **Step 1: Write the failing test** — append to `tests/test_backend.lua` (it already `require`s `Backend` and `mocks`, and the mock thruster implements `setPower`):

```lua
t.test("setThrusterLevel writes setPower(level) to the bound peripheral", function()
  local th = mocks.thruster()
  local shim = mocks.shim({ thruster_1 = th })
  local b = Backend.new(shim, { thrusters = { FL = "thruster_1" }, sensors = {}, bindings = {} })
  b:setThrusterLevel("FL", 11); t.near(th.thrust, 11, 1e-9)
  b:setThrusterLevel("FL", 0);  t.near(th.thrust, 0, 1e-9)
end)
t.test("setThrusterLevel on an unbound id is a harmless no-op", function()
  local b = Backend.new(mocks.shim({}), { thrusters = { FL = false }, sensors = {}, bindings = {} })
  b:setThrusterLevel("FL", 7)   -- must not error
  t.truthy(true)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAILED — `setThrusterLevel` is nil (attempt to call a nil method).

- [ ] **Step 3: Write the implementation** — in `fcs/io/backend.lua`, add this method next to the existing `Backend:setThruster` (do not modify `setThruster`):

```lua
function Backend:setThrusterLevel(id, level)
  local p = self:_periph(self.config.thrusters[id])
  if p then p.setPower(level) end   -- 0..15; wrapped peripherals take NO self
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: OK — all suites pass.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/backend.lua tests/test_backend.lua
git commit -m "feat(io): Backend:setThrusterLevel writes setPower(0..15) for the level actuator"
```

---

### Task 3: Rewire the runner + installer to the level actuator

**Files:**
- Modify: `tools/hover_test.lua` (`buildLoop` + requires)
- Modify: `tools/install_hovertest.lua` (FILES list)

**Interfaces:**
- Consumes: `fcs.actuate.level` (Task 1), `Backend:setThrusterLevel` (Task 2), existing `Loop` (its `Loop:apply` already sends all duties to the `pwm` slot when `sd` is nil — no `Loop` change).
- Produces: the flight runner drives all thrusters through the level actuator.

- [ ] **Step 1: Swap the requires** — in `tools/hover_test.lua`, near the top, replace the two lines:

```lua
local Pwm      = require("fcs.actuate.pwm")
local SD       = require("fcs.actuate.sigma_delta")
```
with:
```lua
local Level    = require("fcs.actuate.level")
```

- [ ] **Step 2: Rewire `buildLoop`** — in `tools/hover_test.lua`, replace the `Loop.new{...}` call inside `buildLoop`. Change:

```lua
  return Loop.new({ scheme = scheme, mixer = Mixer.new(),
    pwm = Pwm.new({ period = tuning.pwmPeriod, backend = backend }),
    sd = SD.new({ backend = backend }),
    backend = backend, dtMax = tuning.dtMax, caps = tuning.caps, osc = tuning.osc })
```
to:
```lua
  return Loop.new({ scheme = scheme, mixer = Mixer.new(),
    pwm = Level.new({ backend = backend, steps = 15 }),
    sd = nil,
    backend = backend, dtMax = tuning.dtMax, caps = tuning.caps, osc = tuning.osc })
```

(Leave `tuning.pwmPeriod` in `fcs/tuning.lua` untouched — the sim/tests still use it. It is simply no longer read by the runner.)

- [ ] **Step 3: Add the new file to the installer** — in `tools/install_hovertest.lua`, add `"fcs/actuate/level.lua"` to the `FILES` table (anywhere; e.g. right after `"fcs/actuate/sigma_delta.lua"`). Leave the existing pwm/sigma_delta entries in place (harmless).

- [ ] **Step 4: Verify the repo is still green** — the runner shell is validated only by its require-load smoke (`tests/test_hover_test.lua`), which now pulls in `fcs.actuate.level`.

Run: `bash tests/run_headless.sh`
Expected: OK — the smoke require-loads `tools/hover_test.lua` (proving it parses and every `require` resolves, including the new `fcs.actuate.level`). `run()` itself is never executed by the suite.

- [ ] **Step 5: Commit**

```bash
git add tools/hover_test.lua tools/install_hovertest.lua
git commit -m "feat(bringup): flight runner drives thrusters via the direct 16-level actuator"
```

- [ ] **Step 6: Tag the completed plan**

```bash
git tag -a level-actuator -m "Direct 16-level thruster actuator (flight-rate fix)"
```

---

## After merge (in-game, pilot — not automated)

1. Re-run `install_hovertest` on the FCS PC, then `hovertest` and fly the usual climb/hold/land.
2. **Primary success check:** in the CSV, the `hz`/`dt_ms` columns should now stay high (**~15–18 Hz, dt ~50–70 ms**) *during flight*, not just idle — direct proof the write-throttle is gone.
3. Then judge attitude stability. Expect it to be far more controllable; **re-tune from there** (the higher rate may allow firmer gains than the current detuned set — a separate in-flight iteration, out of scope here).
4. **If it regresses badly:** roll back with `git reset --hard pre-level-actuator` (commit `bd4e9a5`) and re-install.

## Self-Review

**Spec coverage:** §3.1 level actuator → Task 1; §3.2 `setThrusterLevel` → Task 2; §3.3 runner rewire → Task 3 Steps 1–2; §6 installer → Task 3 Step 3; §5 tests → Tasks 1–2. No `Loop`/tuning/control change (Global Constraints enforce). ✓

**Placeholder scan:** none — every step has literal code. ✓

**Type consistency:** `Level.new(cfg)/:apply(duties,dt)/:state(id)` defined in Task 1 and consumed by the runner in Task 3; `backend:setThrusterLevel(id, level)` produced in Task 2 and called by the actuator in Task 1 (the Task 1 test uses a fake with the same signature). Actuator drops into the `Loop` `pwm` slot with `sd = nil`, matching `pwm.lua`'s interface. ✓

**Rounding note:** `quantize` uses `math.floor(v + 0.5)` (round-half-up), matching the test expectations (0.5→8, 0.2→3, 0.52→8, 0.6→9). ✓
