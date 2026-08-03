# FCS Core Kernel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the EasyHover 2 flight-control kernel and prove it holds a stable, level hover at a commanded altitude in a headless plant simulator — no limit cycle, no windup, no dt-spike kick.

**Architecture:** A rate-adaptive control runtime drives a pluggable control **scheme** (`LevelFlight`: decoupled per-axis PI(D) loops) whose demands go through a **mixer** into a synchronized **bang-bang PWM** layer, which writes on/off states to a **backend**. The simulator is one backend implementing the same interface real CC:Tweaked hardware will implement in a later plan, so the entire kernel is developed and tested without Minecraft.

**Tech Stack:** Lua 5.1 (CC:Tweaked / CraftOS-PC semantics). Headless tests run under CraftOS-PC console. No external libraries.

## Global Constraints

- **Language/runtime:** Lua 5.1 as shipped in CC:Tweaked. No `goto`, no integer `//`, use `math.floor`. No external modules; only the standard library plus our own files.
- **Testing:** headless via CraftOS-PC console, driven by `bash tests/run_headless.sh` (the workspace's allow-listed pattern). Every module is pure Lua with **no CC peripheral calls** in this plan — the backend interface is the only seam to hardware, and its only concrete implementation here is the simulator.
- **No fixed time step, no hardcoded loop rate.** `dt` is a parameter everywhere; every tunable is expressed **per second**, never per cycle.
- **Signs:** in this plan the simulator's axis signs are known and fixed; the real calibration-measured binding arrives in the hardware-IO plan. Keep sign handling in the frame module so it is swappable.
- **Discipline:** DRY, YAGNI (build only the lift group + vertical/rotational plant this milestone needs — lateral/main/frontal thrusters and horizontal loops are the next plan), TDD (test first, watch it fail, minimal code, watch it pass), commit after every green task.
- **Line endings:** LF.

---

## File structure

```
EasyHover2/
  fcs/
    frame.lua              canonical axes, sign helpers (swappable binding)
    control/pid.lua        one PI(D) controller type (Kd 0 => PI)
    mixer/level_flight.lua LevelFlight mixer: lift group (heave/pitch/roll -> 4 duties)
    actuate/pwm.lua        synchronized bang-bang PWM + write scheduler
    schemes/level_flight.lua  ControlLoopSet: altitude + pitch + roll loops
    runtime/loop.lua       rate-adaptive cycle: sensors->scheme->mixer->pwm; arm + ground gate
  tests/
    framework.lua          tiny assert/test collector
    run_headless.sh        copies tree into CraftOS-PC data dir, runs, reads /results.txt
    startup.lua            (generated into data dir) requires suites, writes results, shuts down
    sim.lua                plant simulator + sim backend (implements the backend interface)
    test_pid.lua
    test_pwm.lua
    test_mixer.lua
    test_sim.lua
    test_integration.lua
```

**Backend interface** (the one seam to hardware; simulator implements it here):
- `backend:sensors() -> table` — frame-bound measurements: `{altitude, vSpeed, pitch, pitchRate, roll, rollRate, onGround}` (this plan; extended later).
- `backend:liftIds() -> {id,...}` — stable ids of the 4 lift thrusters, order `FL,FR,RL,RR`.
- `backend:setThruster(id, on)` — set a thruster on/off. Called only on state change.

---

## Task 1: Test harness

**Files:**
- Create: `tests/framework.lua`
- Create: `tests/run_headless.sh`
- Create: `tests/test_smoke.lua`

**Interfaces:**
- Produces: `framework.test(name, fn)`, `framework.eq(a,b[,msg])`, `framework.near(a,b,tol[,msg])`, `framework.truthy(v[,msg])`, `framework.run() -> ok, summary`.

- [ ] **Step 1: Write the failing test** — `tests/test_smoke.lua`

```lua
local t = require("tests.framework")
t.test("framework adds numbers", function()
  t.eq(1 + 1, 2)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `tests.framework` not found.

- [ ] **Step 3: Write minimal implementation** — `tests/framework.lua`

```lua
local M = { _cases = {} }
function M.test(name, fn) M._cases[#M._cases+1] = { name = name, fn = fn } end
function M.eq(a, b, msg)
  if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. " got " .. tostring(a), 2) end
end
function M.near(a, b, tol, msg)
  if math.abs(a - b) > tol then error((msg or "near") .. ": " .. tostring(a) .. " vs " .. tostring(b) .. " tol " .. tostring(tol), 2) end
end
function M.truthy(v, msg) if not v then error((msg or "truthy") .. ": got " .. tostring(v), 2) end end
function M.run()
  local pass, fail, lines = 0, 0, {}
  for _, c in ipairs(M._cases) do
    local ok, err = pcall(c.fn)
    if ok then pass = pass + 1 else fail = fail + 1; lines[#lines+1] = "FAIL " .. c.name .. ": " .. tostring(err) end
  end
  lines[#lines+1] = ("%d passed, %d failed"):format(pass, fail)
  return fail == 0, table.concat(lines, "\n")
end
return M
```

And `tests/run_headless.sh` (writes a startup into a fresh data dir, runs CraftOS-PC, prints results):

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$(mktemp -d)"
COMP="$DATA/computer/0"
mkdir -p "$COMP"
cp -r "$ROOT/fcs" "$ROOT/tests" "$COMP/"
cat > "$COMP/startup.lua" <<'LUA'
package.path = "/?.lua;/?/init.lua;" .. package.path
local suites = { "tests.test_smoke", "tests.test_pid", "tests.test_pwm",
                 "tests.test_mixer", "tests.test_sim", "tests.test_integration" }
local t = require("tests.framework")
for _, s in ipairs(suites) do pcall(require, s) end
local ok, summary = t.run()
local f = fs.open("/results.txt", "w"); f.write((ok and "OK\n" or "FAILED\n") .. summary); f.close()
os.shutdown()
LUA
timeout 60 "/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe" --headless -d "$DATA" >/dev/null 2>&1 || true
cat "$COMP/../0/results.txt"
grep -q '^OK' "$COMP/results.txt"
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: prints `OK` and `1 passed, 0 failed`; exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/framework.lua tests/run_headless.sh tests/test_smoke.lua
git commit -m "test: headless CraftOS-PC harness + assertion framework"
```

---

## Task 2: PID controller — proportional term

**Files:**
- Create: `fcs/control/pid.lua`
- Test: `tests/test_pid.lua`

**Interfaces:**
- Produces: `Pid.new(cfg) -> pid`; `pid:update(setpoint, measurement, dt[, saturated]) -> output`; `pid:reset()`.
  `cfg = {kp, ki, kd, tauD, iMin, iMax, dtMax}` (all numbers; `tauD` = derivative filter time constant in seconds).

- [ ] **Step 1: Write the failing test** — add to `tests/test_pid.lua`

```lua
local t = require("tests.framework")
local Pid = require("fcs.control.pid")
t.test("P term is kp*error", function()
  local p = Pid.new({ kp = 2, ki = 0, kd = 0 })
  t.near(p:update(10, 4, 0.1), 12, 1e-9)   -- 2 * (10-4)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `fcs.control.pid` not found.

- [ ] **Step 3: Write minimal implementation** — `fcs/control/pid.lua`

```lua
local Pid = {}
Pid.__index = Pid
function Pid.new(cfg)
  local self = setmetatable({}, Pid)
  self.kp = cfg.kp or 0; self.ki = cfg.ki or 0; self.kd = cfg.kd or 0
  self.tauD = cfg.tauD or 0
  self.iMin = cfg.iMin or -math.huge; self.iMax = cfg.iMax or math.huge
  self.dtMax = cfg.dtMax or 0.5
  self:reset()
  return self
end
function Pid:reset() self.i = 0; self.lastMeas = nil; self.dFilt = 0 end
function Pid:update(sp, meas, dt, saturated)
  local err = sp - meas
  return self.kp * err
end
return Pid
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/control/pid.lua tests/test_pid.lua
git commit -m "feat(pid): proportional term"
```

---

## Task 3: PID — integral, clamp, and conditional integration

**Files:**
- Modify: `fcs/control/pid.lua`
- Test: `tests/test_pid.lua`

**Interfaces:**
- Consumes: `Pid.new`, `pid:update` from Task 2.
- Produces: `update` now accumulates integral (`i += ki*err*dt`), clamps `i` to `[iMin,iMax]`, and **freezes integration when `saturated` is true**.

- [ ] **Step 1: Write the failing tests** — add to `tests/test_pid.lua`

```lua
t.test("I accumulates over time", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 0 })
  p:update(1, 0, 0.5); p:update(1, 0, 0.5)     -- err=1 each, dt=0.5 -> i=1.0
  t.near(p:update(1, 0, 0), 1.0, 1e-9)         -- dt=0 adds nothing; output = i
end)
t.test("I clamps to iMax (anti-windup)", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 0, iMax = 0.3 })
  for _ = 1, 100 do p:update(1, 0, 0.1) end
  t.near(p:update(1, 0, 0), 0.3, 1e-9)
end)
t.test("saturated freezes integration", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 0 })
  p:update(1, 0, 0.5)                          -- i = 0.5
  p:update(1, 0, 0.5, true)                    -- saturated: no change
  t.near(p:update(1, 0, 0), 0.5, 1e-9)
end)
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run_headless.sh`
Expected: FAIL — output ignores integral.

- [ ] **Step 3: Write minimal implementation** — replace `Pid:update` in `fcs/control/pid.lua`

```lua
function Pid:update(sp, meas, dt, saturated)
  local err = sp - meas
  if not saturated and dt > 0 then
    self.i = self.i + self.ki * err * dt
    if self.i > self.iMax then self.i = self.iMax elseif self.i < self.iMin then self.i = self.iMin end
  end
  return self.kp * err + self.i
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/control/pid.lua tests/test_pid.lua
git commit -m "feat(pid): integral with clamp and conditional integration"
```

---

## Task 4: PID — filtered derivative on measurement, with Kd=0 bypass

**Files:**
- Modify: `fcs/control/pid.lua`
- Test: `tests/test_pid.lua`

**Interfaces:**
- Produces: derivative computed on the **measurement** (negated), low-pass filtered with time constant `tauD` via `alpha = dt/(tauD+dt)`; when `kd == 0` the derivative path is skipped entirely (no filter state touched).

- [ ] **Step 1: Write the failing tests** — add to `tests/test_pid.lua`

```lua
t.test("D opposes a rising measurement", function()
  local p = Pid.new({ kp = 0, ki = 0, kd = 1, tauD = 0 })  -- tauD 0 => alpha 1, unfiltered
  p:update(0, 0, 0.1)                        -- seed lastMeas
  local out = p:update(0, 1, 0.1)            -- meas rose 1 over 0.1 => dMeas=10, D=-10
  t.near(out, -10, 1e-9)
end)
t.test("Kd 0 fully bypasses derivative (no crash, pure PI)", function()
  local p = Pid.new({ kp = 1, ki = 0, kd = 0 })
  t.near(p:update(0, 5, 0.1), -5, 1e-9)      -- only P, even with a moving measurement
  t.near(p:update(0, 9, 0.1), -9, 1e-9)
end)
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run_headless.sh`
Expected: FAIL — no derivative term yet.

- [ ] **Step 3: Write minimal implementation** — replace `Pid:update`

```lua
function Pid:update(sp, meas, dt, saturated)
  local err = sp - meas
  if not saturated and dt > 0 then
    self.i = self.i + self.ki * err * dt
    if self.i > self.iMax then self.i = self.iMax elseif self.i < self.iMin then self.i = self.iMin end
  end
  local d = 0
  if self.kd ~= 0 then
    if self.lastMeas ~= nil and dt > 0 then
      local dMeas = (meas - self.lastMeas) / dt
      local alpha = dt / (self.tauD + dt)
      self.dFilt = self.dFilt + alpha * (dMeas - self.dFilt)
      d = -self.kd * self.dFilt
    end
    self.lastMeas = meas
  end
  return self.kp * err + self.i + d
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/control/pid.lua tests/test_pid.lua
git commit -m "feat(pid): filtered derivative on measurement; Kd=0 bypass"
```

---

## Task 5: PID — dt discipline (no kick on a stall)

**Files:**
- Modify: `fcs/control/pid.lua`
- Test: `tests/test_pid.lua`

**Interfaces:**
- Produces: when `dt <= 0` or `dt > dtMax`, `update` **skips integration and derivative for that cycle** (outputs `P + held I` only) and does **not** update `lastMeas`/`dFilt`, so a `dt` spike cannot produce a derivative kick.

- [ ] **Step 1: Write the failing test** — add to `tests/test_pid.lua`

```lua
t.test("dt spike produces no derivative kick", function()
  local p = Pid.new({ kp = 0, ki = 0, kd = 1, tauD = 0, dtMax = 0.5 })
  p:update(0, 0, 0.1)                        -- seed
  local out = p:update(0, 100, 5.0)          -- huge jump AND huge dt (a stall)
  t.near(out, 0, 1e-9)                        -- skipped: no kick
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — derivative still fires on the spike.

- [ ] **Step 3: Write minimal implementation** — guard the update

```lua
function Pid:update(sp, meas, dt, saturated)
  local err = sp - meas
  local usable = (dt > 0) and (dt <= self.dtMax) and not saturated
  if usable then
    self.i = self.i + self.ki * err * dt
    if self.i > self.iMax then self.i = self.iMax elseif self.i < self.iMin then self.i = self.iMin end
  end
  local d = 0
  if self.kd ~= 0 and usable then
    if self.lastMeas ~= nil then
      local dMeas = (meas - self.lastMeas) / dt
      local alpha = dt / (self.tauD + dt)
      self.dFilt = self.dFilt + alpha * (dMeas - self.dFilt)
      d = -self.kd * self.dFilt
    end
    self.lastMeas = meas
  end
  return self.kp * err + self.i + d
end
```

Note: a normal-`dt` cycle with `kd~=0` still seeds `lastMeas` on the first call (the `d` stays 0 that cycle because `lastMeas` was nil). A spike leaves `lastMeas` untouched so the *next* good cycle differentiates against the last *good* sample.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS (and Task 4's tests still pass).

- [ ] **Step 5: Commit**

```bash
git add fcs/control/pid.lua tests/test_pid.lua
git commit -m "feat(pid): dt discipline — skip integ/deriv on spike, no kick"
```

---

## Task 6: Synchronized bang-bang PWM + write scheduler

**Files:**
- Create: `fcs/actuate/pwm.lua`
- Test: `tests/test_pwm.lua`

**Interfaces:**
- Produces: `Pwm.new({period, backend}) -> pwm`; `pwm:apply(duties, dt)` where `duties` is `{[id]=0..1}`. Maintains a **single shared phase** in `[0,1)` advanced by `dt/period`; thruster `id` is on when `duties[id] > phase`. Calls `backend:setThruster(id, on)` **only when a thruster's state changes**. `pwm:state(id) -> bool`.

- [ ] **Step 1: Write the failing tests** — `tests/test_pwm.lua`

```lua
local t = require("tests.framework")
local Pwm = require("fcs.actuate.pwm")
local function recBackend()
  local b = { writes = 0, on = {} }
  function b:setThruster(id, s) self.writes = self.writes + 1; self.on[id] = s end
  return b
end
t.test("duty 1 always on, duty 0 always off", function()
  local b = recBackend(); local p = Pwm.new({ period = 1, backend = b })
  for _ = 1, 20 do p:apply({ a = 1.0, z = 0.0 }, 0.05) end
  t.truthy(p:state("a") == true); t.truthy(p:state("z") == false)
end)
t.test("equal duties toggle in lockstep (synchronized)", function()
  local b = recBackend(); local p = Pwm.new({ period = 1, backend = b })
  local diff = 0
  for _ = 1, 100 do p:apply({ a = 0.5, c = 0.5 }, 0.03); if p:state("a") ~= p:state("c") then diff = diff + 1 end end
  t.eq(diff, 0)                              -- never disagree => zero moment ripple
end)
t.test("writes happen only on change", function()
  local b = recBackend(); local p = Pwm.new({ period = 1, backend = b })
  for _ = 1, 10 do p:apply({ a = 1.0 }, 0.05) end
  t.eq(b.writes, 1)                          -- turned on once, never re-written
end)
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `fcs.actuate.pwm` not found.

- [ ] **Step 3: Write minimal implementation** — `fcs/actuate/pwm.lua`

```lua
local Pwm = {}
Pwm.__index = Pwm
function Pwm.new(cfg)
  return setmetatable({ period = cfg.period or 0.5, backend = cfg.backend, phase = 0, on = {} }, Pwm)
end
function Pwm:state(id) return self.on[id] == true end
function Pwm:apply(duties, dt)
  if self.period > 0 and dt > 0 then
    self.phase = (self.phase + dt / self.period) % 1
  end
  for id, duty in pairs(duties) do
    local want = duty > self.phase
    if self.on[id] ~= want then
      self.on[id] = want
      self.backend:setThruster(id, want)
    end
  end
end
return Pwm
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/actuate/pwm.lua tests/test_pwm.lua
git commit -m "feat(pwm): synchronized bang-bang, write-on-change scheduler"
```

---

## Task 7: LevelFlight mixer — lift group

**Files:**
- Create: `fcs/frame.lua`
- Create: `fcs/mixer/level_flight.lua`
- Test: `tests/test_mixer.lua`

**Interfaces:**
- Produces: `frame.LIFT = {"FL","FR","RL","RR"}`; `Mixer.new() -> mixer`; `mixer:mix(demands) -> {[id]=duty}` for the four lift ids, where `demands = {heave, pitch, roll}` and
  `FL=heave+pitch+roll, FR=heave+pitch-roll, RL=heave-pitch+roll, RR=heave-pitch-roll`, each **clamped to [0,1]**.

- [ ] **Step 1: Write the failing tests** — `tests/test_mixer.lua`

```lua
local t = require("tests.framework")
local Mixer = require("fcs.mixer.level_flight")
t.test("pure heave = equal duties, no moment", function()
  local d = Mixer.new():mix({ heave = 0.5, pitch = 0, roll = 0 })
  t.near(d.FL, 0.5, 1e-9); t.near(d.FR, 0.5, 1e-9); t.near(d.RL, 0.5, 1e-9); t.near(d.RR, 0.5, 1e-9)
end)
t.test("nose-up pitch raises front duties, lowers rear", function()
  local d = Mixer.new():mix({ heave = 0.5, pitch = 0.1, roll = 0 })
  t.near(d.FL, 0.6, 1e-9); t.near(d.RL, 0.4, 1e-9)
end)
t.test("duties clamp to [0,1]", function()
  local d = Mixer.new():mix({ heave = 1.0, pitch = 0.5, roll = 0 })
  t.near(d.FL, 1.0, 1e-9); t.near(d.RL, 0.5, 1e-9)
end)
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run_headless.sh`
Expected: FAIL — modules not found.

- [ ] **Step 3: Write minimal implementation**

`fcs/frame.lua`:

```lua
return { LIFT = { "FL", "FR", "RL", "RR" } }
```

`fcs/mixer/level_flight.lua`:

```lua
local Mixer = {}
Mixer.__index = Mixer
function Mixer.new() return setmetatable({}, Mixer) end
local function clamp(v) if v < 0 then return 0 elseif v > 1 then return 1 else return v end end
function Mixer:mix(d)
  local h, p, r = d.heave or 0, d.pitch or 0, d.roll or 0
  return {
    FL = clamp(h + p + r), FR = clamp(h + p - r),
    RL = clamp(h - p + r), RR = clamp(h - p - r),
  }
end
return Mixer
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/frame.lua fcs/mixer/level_flight.lua tests/test_mixer.lua
git commit -m "feat(mixer): LevelFlight lift group (heave/pitch/roll -> 4 duties)"
```

---

## Task 8: Plant simulator + sim backend

**Files:**
- Create: `tests/sim.lua`
- Test: `tests/test_sim.lua`

**Interfaces:**
- Produces: `Sim.new(cfg) -> sim` implementing the **backend interface** (`sim:sensors()`, `sim:liftIds()`, `sim:setThruster(id,on)`) plus `sim:step(dt)` (advances physics from current thruster on/off states).
  `cfg = {mass, g, fPer, inertia, armX, armZ}`. Corners: FL(+z,+x... ) per `frame`. Vertical accel `= (sum on * fPer)/mass - g`. Pitch moment `= fPer*(front - rear)*armZ`, roll moment `= fPer*(left - right)*armX`; angular accel `= moment/inertia`. Sign convention: front = FL,FR; right = FR,RR; +pitch nose-up from more front thrust; +roll right-wing-down from more right thrust... (encode exactly in code below).

- [ ] **Step 1: Write the failing tests** — `tests/test_sim.lua`

```lua
local t = require("tests.framework")
local Sim = require("tests.sim")
local function hoverCfg() return { mass = 4, g = 10, fPer = 15, inertia = 2, armX = 1, armZ = 1 } end
t.test("all four lift on climbs; none falls", function()
  local s = Sim.new(hoverCfg())
  for _, id in ipairs(s:liftIds()) do s:setThruster(id, true) end
  s:step(0.1)
  t.truthy(s:sensors().vSpeed > 0)           -- 60N up vs 40N weight => climbs
  local s2 = Sim.new(hoverCfg()); s2:step(0.1)
  t.truthy(s2:sensors().vSpeed < 0)          -- all off => falls
end)
t.test("front pair only pitches nose up", function()
  local s = Sim.new(hoverCfg())
  s:setThruster("FL", true); s:setThruster("FR", true)
  s:step(0.1)
  t.truthy(s:sensors().pitchRate > 0)
end)
t.test("right pair only rolls right-wing-down", function()
  local s = Sim.new(hoverCfg())
  s:setThruster("FR", true); s:setThruster("RR", true)
  s:step(0.1)
  t.truthy(s:sensors().rollRate > 0)
end)
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `tests.sim` not found.

- [ ] **Step 3: Write minimal implementation** — `tests/sim.lua`

```lua
local frame = require("fcs.frame")
local Sim = {}
Sim.__index = Sim
-- corner geometry: FL front-left, FR front-right, RL rear-left, RR rear-right
local FRONT = { FL = 1, FR = 1, RL = -1, RR = -1 }   -- +1 front, -1 rear
local RIGHT = { FL = -1, FR = 1, RL = -1, RR = 1 }   -- +1 right, -1 left
function Sim.new(cfg)
  local self = setmetatable({ cfg = cfg, on = {} }, Sim)
  self.altitude, self.vSpeed = 0, 0
  self.pitch, self.pitchRate = 0, 0
  self.roll, self.rollRate = 0, 0
  for _, id in ipairs(frame.LIFT) do self.on[id] = false end
  return self
end
function Sim:liftIds() return frame.LIFT end
function Sim:setThruster(id, s) self.on[id] = s and true or false end
function Sim:step(dt)
  local c = self.cfg
  local fz, pm, rm = 0, 0, 0
  for _, id in ipairs(frame.LIFT) do
    if self.on[id] then
      fz = fz + c.fPer
      pm = pm + c.fPer * FRONT[id] * c.armZ
      rm = rm + c.fPer * RIGHT[id] * c.armX
    end
  end
  local aV = fz / c.mass - c.g
  self.vSpeed = self.vSpeed + aV * dt
  self.altitude = self.altitude + self.vSpeed * dt
  if self.altitude < 0 then self.altitude, self.vSpeed = 0, math.max(0, self.vSpeed) end
  self.pitchRate = self.pitchRate + (pm / c.inertia) * dt
  self.pitch = self.pitch + self.pitchRate * dt
  self.rollRate = self.rollRate + (rm / c.inertia) * dt
  self.roll = self.roll + self.rollRate * dt
end
function Sim:sensors()
  return { altitude = self.altitude, vSpeed = self.vSpeed,
           pitch = self.pitch, pitchRate = self.pitchRate,
           roll = self.roll, rollRate = self.rollRate,
           onGround = (self.altitude <= 0 and math.abs(self.vSpeed) < 0.01) }
end
return Sim
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS. Each direction test fails if its sign is flipped — verify by temporarily flipping `FRONT`/`RIGHT` and re-running (pins physics against physics, not against the controller).

- [ ] **Step 5: Commit**

```bash
git add tests/sim.lua tests/test_sim.lua
git commit -m "test(sim): bang-bang vertical + pitch/roll plant, signs pinned"
```

---

## Task 9: LevelFlight scheme — altitude + attitude loops

**Files:**
- Create: `fcs/schemes/level_flight.lua`
- Test: add to `tests/test_integration.lua`

**Interfaces:**
- Produces: `Scheme.new(cfg) -> scheme`; `scheme:update(setpoints, meas, dt) -> demands`; `scheme:reset()`.
  `setpoints = {altitude, pitch=0, roll=0}`; returns `{heave, pitch, roll}`. Internals: three `Pid`s. `heave = hoverDuty + altPid(sp.altitude, meas.altitude)`; `pitch = pitchPid(0, meas.pitch)`; `roll = rollPid(0, meas.roll)`. `cfg` carries `hoverDuty` and the three gain sets.

- [ ] **Step 1: Write the failing test** — start `tests/test_integration.lua`

```lua
local t = require("tests.framework")
local Scheme = require("fcs.schemes.level_flight")
t.test("scheme outputs hover heave at altitude setpoint, level", function()
  local sc = Scheme.new({
    hoverDuty = 0.66,
    alt = { kp = 0.05, ki = 0.0, kd = 0.0 },
    pitch = { kp = 0.2, ki = 0, kd = 0.05, tauD = 0.2 },
    roll = { kp = 0.2, ki = 0, kd = 0.05, tauD = 0.2 },
  })
  local d = sc:update({ altitude = 10, pitch = 0, roll = 0 },
                      { altitude = 10, vSpeed = 0, pitch = 0, pitchRate = 0, roll = 0, rollRate = 0 }, 0.1)
  t.near(d.heave, 0.66, 1e-9); t.near(d.pitch, 0, 1e-9); t.near(d.roll, 0, 1e-9)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `fcs.schemes.level_flight` not found.

- [ ] **Step 3: Write minimal implementation** — `fcs/schemes/level_flight.lua`

```lua
local Pid = require("fcs.control.pid")
local Scheme = {}
Scheme.__index = Scheme
function Scheme.new(cfg)
  local self = setmetatable({ hoverDuty = cfg.hoverDuty or 0.5 }, Scheme)
  self.altPid = Pid.new(cfg.alt or {})
  self.pitchPid = Pid.new(cfg.pitch or {})
  self.rollPid = Pid.new(cfg.roll or {})
  return self
end
function Scheme:reset() self.altPid:reset(); self.pitchPid:reset(); self.rollPid:reset() end
function Scheme:update(sp, m, dt)
  return {
    heave = self.hoverDuty + self.altPid:update(sp.altitude, m.altitude, dt),
    pitch = self.pitchPid:update(sp.pitch or 0, m.pitch, dt),
    roll = self.rollPid:update(sp.roll or 0, m.roll, dt),
  }
end
return Scheme
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/schemes/level_flight.lua tests/test_integration.lua
git commit -m "feat(scheme): LevelFlight altitude + attitude loops"
```

---

## Task 10: Runtime — rate-adaptive cycle, arm, ground gate

**Files:**
- Create: `fcs/runtime/loop.lua`
- Test: add to `tests/test_integration.lua`

**Interfaces:**
- Consumes: a `scheme`, a `mixer`, a `pwm`, a `backend`.
- Produces: `Loop.new({scheme, mixer, pwm, backend, dtMax}) -> loop`; `loop:setpoints(t)`; `loop:arm(bool)`; `loop:cycle(dt)`. When **disarmed**: all lift thrusters commanded off, scheme reset, mixer/pwm not run. When **onGround**: integrators frozen (pass `saturated=true` semantics via a frozen flag) — for this plan, ground-freeze is implemented by resetting the scheme each disarmed/ground cycle. `cycle` clamps `dt` to `[0, dtMax]` before use.

- [ ] **Step 1: Write the failing tests** — add to `tests/test_integration.lua`

```lua
local Loop = require("fcs.runtime.loop")
local Mixer = require("fcs.mixer.level_flight")
local Pwm = require("fcs.actuate.pwm")
local Sim = require("tests.sim")
local function build()
  local sim = Sim.new({ mass = 4, g = 10, fPer = 15, inertia = 2, armX = 1, armZ = 1 })
  local sc = Scheme.new({ hoverDuty = 0.66,
    alt = { kp = 0.05, ki = 0.02, kd = 0.0, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.3, ki = 0, kd = 0.08, tauD = 0.2 },
    roll = { kp = 0.3, ki = 0, kd = 0.08, tauD = 0.2 } })
  local loop = Loop.new({ scheme = sc, mixer = Mixer.new(),
    pwm = Pwm.new({ period = 0.3, backend = sim }), backend = sim, dtMax = 0.5 })
  return loop, sim
end
t.test("disarmed on the ground commands no thrust", function()
  local loop, sim = build()
  loop:arm(false); loop:setpoints({ altitude = 5, pitch = 0, roll = 0 })
  for _ = 1, 20 do loop:cycle(0.05); sim:step(0.05) end
  t.truthy(sim:sensors().altitude <= 0)      -- never left the ground
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `fcs.runtime.loop` not found.

- [ ] **Step 3: Write minimal implementation** — `fcs/runtime/loop.lua`

```lua
local frame = require("fcs.frame")
local Loop = {}
Loop.__index = Loop
function Loop.new(cfg)
  return setmetatable({ scheme = cfg.scheme, mixer = cfg.mixer, pwm = cfg.pwm,
    backend = cfg.backend, dtMax = cfg.dtMax or 0.5, sp = {}, armed = false }, Loop)
end
function Loop:setpoints(t) self.sp = t end
function Loop:arm(b) self.armed = b and true or false end
function Loop:cycle(dt)
  if dt < 0 then dt = 0 elseif dt > self.dtMax then dt = self.dtMax end
  local m = self.backend:sensors()
  if not self.armed then
    self.scheme:reset()
    for _, id in ipairs(frame.LIFT) do
      self.pwm:apply({ [id] = 0 }, dt)
    end
    return
  end
  local demands = self.scheme:update(self.sp, m, dt)
  local duties = self.mixer:mix(demands)
  self.pwm:apply(duties, dt)
end
return Loop
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/loop.lua tests/test_integration.lua
git commit -m "feat(runtime): rate-adaptive cycle with arm + dt clamp"
```

---

## Task 11: Acceptance — stable level hover, no limit cycle, no kick

**Files:**
- Test: add to `tests/test_integration.lua`

**Interfaces:**
- Consumes: `build()` from Task 10.
- Produces: the milestone acceptance suite. Drives `loop:cycle(dt)` + `sim:step(dt)` with **variable dt** and asserts the design's §13 contract.

- [ ] **Step 1: Write the failing tests** — add to `tests/test_integration.lua`

```lua
local function fly(loop, sim, seconds, dtFn)
  local tsec, peaks, lastErr, rising = 0, {}, nil, false
  while tsec < seconds do
    local dt = dtFn(tsec)
    loop:cycle(dt); sim:step(dt); tsec = tsec + dt
    local err = math.abs(10 - sim:sensors().altitude)
    if lastErr and err > lastErr and not rising then rising = true end
    if lastErr and err < lastErr and rising then peaks[#peaks+1] = lastErr; rising = false end
    lastErr = err
  end
  return sim:sensors(), peaks
end
t.test("settles to altitude 10 and stays level", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  local s = (fly(loop, sim, 40, function() return 0.1 end))
  t.near(s.altitude, 10, 0.6)                -- within tolerance
  t.near(s.pitch, 0, 0.05); t.near(s.roll, 0, 0.05)
end)
t.test("no limit cycle: late oscillation amplitude decreasing", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  local _, peaks = fly(loop, sim, 40, function() return 0.1 end)
  t.truthy(#peaks >= 2)
  t.truthy(peaks[#peaks] <= peaks[#peaks-1] + 1e-6)   -- not growing
end)
t.test("variable dt (jitter) stays stable", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  local seed = 1
  local s = (fly(loop, sim, 40, function() seed = (seed * 1103515245 + 12345) % 2147483648; return 0.05 + (seed % 100) / 1000 end))
  t.near(s.altitude, 10, 1.0)
end)
t.test("a single dt spike causes no altitude kick", function()
  local loop, sim = build(); loop:arm(true); loop:setpoints({ altitude = 10, pitch = 0, roll = 0 })
  fly(loop, sim, 20, function() return 0.1 end)
  local before = sim:sensors().altitude
  loop:cycle(5.0); sim:step(0.1)             -- stall cycle (clamped, integ/deriv skipped)
  t.near(sim:sensors().altitude, before, 0.5)
end)
```

- [ ] **Step 2: Run to verify behavior**

Run: `bash tests/run_headless.sh`
Expected: initially may FAIL on tolerance/limit-cycle — this is the **tuning gate**. Adjust the gains in `build()` (Task 10) per the design's tuning order (§5: attitude P then D, altitude last, small gains — the design warns the vertical band is only a few percent wide; start `alt.kp` ~0.05). Do **not** change module code to pass; change gains, and if a test reveals a real defect, fix the defect.

- [ ] **Step 3: Achieve green**

Iterate gains in `build()` until all four assertions pass. Record the working gains as the seed config for the hardware plan.

- [ ] **Step 4: Run full suite**

Run: `bash tests/run_headless.sh`
Expected: `OK`, all suites passing.

- [ ] **Step 5: Commit + milestone backup**

```bash
git add tests/test_integration.lua
git commit -m "test(fcs): acceptance — stable level hover, no limit cycle, no kick"
mkdir -p backup && cp -r fcs "backup/$(date +%F)_fcs_kernel_hover_green"
git push
```

---

## Self-review

**Spec coverage (design §5, §6, §7, §11, §13):**
- PI(D) with Kd=0 bypass, filtered D on measurement, anti-windup, conditional integration, dt discipline → Tasks 2–5. ✅
- Synchronized bang-bang PWM, write-on-change → Task 6. ✅
- LevelFlight mixer (lift group) → Task 7. ✅
- Plant simulator with bang-bang + signs pinned against physics → Task 8. ✅
- Rate-adaptive runtime, arm/disarm, dt clamp → Task 10. ✅
- §13 acceptance: settles, no limit cycle, jitter-stable, no dt-spike kick → Task 11. ✅
- **Deferred to next plans (intentional, noted in scope):** heading + horizontal loops and the leash; lateral/main/frontal thrusters in the mixer + horizontal plant; oscillation detector + auto-degrade; envelope limiter; additive config module; instrumentation/spans; real CC-peripheral backend + sensor calibration; comms/UI; NAV; Suite.

**Placeholder scan:** every step has real Lua. No TBD/TODO. ✅

**Type consistency:** `backend:sensors/liftIds/setThruster`, `pid:update(sp,meas,dt,saturated)`, `mixer:mix(demands)->{FL,FR,RL,RR}`, `scheme:update(sp,m,dt)->{heave,pitch,roll}`, `pwm:apply(duties,dt)`, `loop:cycle(dt)` — consistent across Tasks 2–11. ✅

---

## Follow-on plans (not this document)

1. **FCS heading + horizontal + safety** — yaw/heading loop, horizontal velocity/position hold with the leash, lateral/main/frontal in the mixer + horizontal plant, oscillation detector + DAMPED HOVER degrade, envelope limiter, additive config, instrumentation/spans.
2. **Hardware IO + in-game bring-up** — the real CC-peripheral backend (Simulated/Propulsion), sensor→frame calibration procedure, thruster wrappers, redstone-relay arming, ground optical, failsafe redstone; probe the open questions in design §17.
3. **Comms + UI** — modem channels, state-stream telemetry, event commands, the cockpit renderer (reported-state only).
4. **NAV integration** — reuse NAV + GPS, absolute station-keeping, autopilot.
5. **Install/update Suite** — `easyhover2_suite.lua`, manifest, role install/update.
```
