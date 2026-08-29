# Fuel Time Estimate (Fuel Calibration Part 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show live fuel **flow (mB/min)** and **time-to-empty** under the tank gauge, derived from the main-tank level on the existing 3 s poll, with a two-layer adaptive smoother.

**Architecture:** A pure `ui/fuelrate.lua` module rings recent `tankMb` samples and returns `{state, mbPerMin, secondsLeft}` via a slow(~60 s) baseline blended toward a fast(~10 s) rate by deviation (snaps on big changes, smooth when steady). The 3 s UI poll feeds it and stores the estimate in `runtime.state`; it is threaded through `buildState` AND `sigFlight` (Part 1 lesson) so `emc_main` repaints; a pure engine-panel seam formats FLOW/LEFT. Entirely UI-side — zero FCS impact.

**Tech Stack:** CC:Tweaked Lua (MC 1.21.1), Basalt 2.0 full build. Host tests via CraftOS-PC headless; peripherals mocked (the rate module is pure).

## Global Constraints

- Lua for CC:Tweaked; wrapped peripheral methods take **NO self**.
- `ui/fuelrate.lua` is PURE (no globals/peripherals/Basalt) → host-testable.
- Positive rate = **draining**; negative = refueling. Baseline is the main **liquid** tank (`runtime.state.tankMb`).
- **Thread the estimate through BOTH `buildState` (app.lua) AND `sigFlight` (renderpolicy.lua), each with a test that drives the real path** — this is the Part 1 fix-wave lesson; do it from the start, not after review.
- Every task is TDD. Run `bash tests/run_headless.sh` (green = "0 failed" AND source "IN SYNC"). After editing source, `bash tools/run_gen.sh`, include `manifest-dev.lua`. Do NOT rebuild `dist/` (`node tools/build.mjs`) until the final task — EXCEPT the controller materializes dist once after Task 1 so `ui/fuelrate.lua` has a minified copy before Task 3 requires it (avoids the manifest-closure hard-error; same pattern as Part 1's fueltable). `run_headless_dist.sh` stale-fail between tasks is expected.
- **New test file `tests/test_fuelrate.lua` MUST be added to the module list in BOTH `tests/run_headless.sh` AND `tests/run_headless_dist.sh`.** All other target test files (`test_region_emc`, `test_basalt_app`, `test_renderpolicy`) already exist and are registered.
- Reference spec: `docs/superpowers/specs/2026-08-29-fuel-time-estimate-design.md`.

---

## File Structure

- **Create** `ui/fuelrate.lua` — pure adaptive rate/time module.
- **Modify** `ui/panels/engine.lua` — pure `flowLabel(est)` / `leftLabel(est)` format seam.
- **Modify** `ui/basalt/app.lua` — construct `runtime.fuelRate`; 3 s poll `push` + store `runtime.state.fuelEst`; thread `fuelEst` in `buildState`.
- **Modify** `ui/basalt/renderpolicy.lua` — add estimate fields to `sigFlight`.
- **Modify** `ui/basalt/regions/emc.lua` — FLOW/LEFT readouts under the tank bar in `M.main`.
- **Tests:** new `tests/test_fuelrate.lua` (register both runners); extend `test_region_emc`, `test_basalt_app`, `test_renderpolicy`.

---

### Task 1: `ui/fuelrate.lua` adaptive rate module

**Files:**
- Create: `ui/fuelrate.lua`
- Create + register: `tests/test_fuelrate.lua`

**Interfaces:**
- Produces: `FuelRate.new(cfg?)` (cfg overrides knobs); `fr:push(mb, tMs)` (ignores non-number); `fr:read()` → `{ state, mbPerMin, secondsLeft }`, `state ∈ "drain"|"idle"|"refuel"|"unknown"`. Positive drain. Knobs: `slowWindowS=60, fastWindowS=10, sensitivity=300, idleEps=20, refuelEps=20, maxSamples=30`.

- [ ] **Step 1: Write the failing test + register the module**

Create `tests/test_fuelrate.lua` (mirror a pure-module test's `local t = require("tests.framework")` + `t.test`/`t.near`/`t.eq` style), AND add `"tests.test_fuelrate"` to the module list in BOTH `tests/run_headless.sh` and `tests/run_headless_dist.sh` (next to another `ui.*` unit test, e.g. `tests.test_ui_toolkit`). Cases (timestamps in ms; drain = tank mb DECREASING over time):

```lua
local t = require("tests.framework")
local FuelRate = require("ui.fuelrate")
t.test("fuelrate: <2 samples -> unknown", function()
  local fr = FuelRate.new(); fr:push(10000, 0)
  t.eq(fr:read().state, "unknown", "unknown until 2 samples")
end)
t.test("fuelrate: steady drain -> mbPerMin + secondsLeft", function()
  local fr = FuelRate.new()
  -- 300 mB per 3s = 6000 mB/min; start 12000 mB
  local mb, tm = 12000, 0
  for i = 1, 8 do fr:push(mb, tm); mb = mb - 300; tm = tm + 3000 end
  local r = fr:read()
  t.eq(r.state, "drain", "draining")
  t.near(r.mbPerMin, 6000, 200, "~6000 mB/min")
  t.near(r.secondsLeft, (mb) / (r.mbPerMin/60), 5, "time = mb/rate")   -- mb is current after loop
end)
t.test("fuelrate: step-up snaps toward fast, not stuck on slow", function()
  local fr = FuelRate.new()
  local mb, tm = 20000, 0
  for i = 1, 15 do fr:push(mb, tm); mb = mb - 150; tm = tm + 3000 end   -- slow drain ~3000/min
  local slowRead = fr:read().mbPerMin
  for i = 1, 3 do fr:push(mb, tm); mb = mb - 900; tm = tm + 3000 end    -- sudden hard drain ~18000/min
  local fastRead = fr:read().mbPerMin
  t.truthy(fastRead > slowRead * 2, "snaps up on a big short-term jump")
end)
t.test("fuelrate: rising tank -> refuel", function()
  local fr = FuelRate.new()
  local mb, tm = 5000, 0
  for i = 1, 6 do fr:push(mb, tm); mb = mb + 500; tm = tm + 3000 end
  t.eq(fr:read().state, "refuel", "rising = refuel")
end)
t.test("fuelrate: near-zero drain -> idle", function()
  local fr = FuelRate.new()
  for i = 0, 6 do fr:push(9000, i * 3000) end   -- flat
  t.eq(fr:read().state, "idle", "flat = idle")
end)
```

- [ ] **Step 2: Run to verify fail** — `bash tests/run_headless.sh` → FAIL (module not found).

- [ ] **Step 3: Implement**

Create `ui/fuelrate.lua`:

```lua
-- ui/fuelrate.lua -- adaptive fuel drain-rate + time-to-empty from main-tank mB samples.
-- Pure (no peripheral/Basalt). Two-layer smoother: a steady slow(~60s) baseline that SNAPS toward
-- a fast(~10s) rate the more they diverge -- calm at steady consumption, reacts within ~2-3 samples
-- to a hover->cruise punch or throttle chop, then re-settles as the slow window ages out. Positive
-- rate = draining. UI-side only (rides the existing 3s tank poll).
local M = {}
M.__index = M
local DEFAULTS = { slowWindowS = 60, fastWindowS = 10, sensitivity = 300, idleEps = 20, refuelEps = 20, maxSamples = 30 }

function M.new(cfg)
  cfg = cfg or {}
  local self = setmetatable({ samples = {}, cfg = {} }, M)
  for k, v in pairs(DEFAULTS) do self.cfg[k] = cfg[k] or v end
  return self
end

function M:push(mb, tMs)
  if type(mb) ~= "number" or type(tMs) ~= "number" then return end
  local s = self.samples
  s[#s + 1] = { mb = mb, t = tMs }
  while #s > self.cfg.maxSamples do table.remove(s, 1) end
end

-- mB/min over ~windowS: newest vs the oldest sample within the window (or s[1] if the ring is
-- shorter). Positive = draining. nil on <2 samples or zero span.
function M:_rateOver(windowS)
  local s, n = self.samples, #self.samples
  if n < 2 then return nil end
  local newest = s[n]
  local limit = windowS * 1000
  local old = s[1]
  for i = 1, n - 1 do
    if (newest.t - s[i].t) <= limit then old = s[i]; break end
  end
  local dtMs = newest.t - old.t
  if dtMs <= 0 then return nil end
  return (old.mb - newest.mb) / dtMs * 60000
end

function M:read()
  local s, n = self.samples, #self.samples
  if n < 2 then return { state = "unknown", mbPerMin = 0, secondsLeft = nil } end
  local slow = self:_rateOver(self.cfg.slowWindowS)
  local fast = self:_rateOver(self.cfg.fastWindowS)
  slow = slow or fast or 0
  fast = fast or slow
  local sens = self.cfg.sensitivity
  local w = (sens > 0) and math.min(1, math.abs(fast - slow) / sens) or 1
  local displayed = slow + w * (fast - slow)            -- signed mB/min
  if displayed < -self.cfg.refuelEps then
    return { state = "refuel", mbPerMin = 0, secondsLeft = nil }
  end
  local mbPerMin = math.max(0, displayed)
  if mbPerMin <= self.cfg.idleEps then
    return { state = "idle", mbPerMin = 0, secondsLeft = nil }
  end
  local curMb = s[n].mb
  local secondsLeft = (type(curMb) == "number" and curMb > 0) and (curMb / (mbPerMin / 60)) or nil
  return { state = "drain", mbPerMin = mbPerMin, secondsLeft = secondsLeft }
end

return M
```

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/fuelrate.lua tests/test_fuelrate.lua tests/run_headless.sh tests/run_headless_dist.sh
git commit -m "feat(ui): fuelrate -- adaptive main-tank drain rate + time-to-empty"
```

---

### Task 2: engine-panel FLOW/LEFT format seam

**Files:**
- Modify: `ui/panels/engine.lua`
- Test: `tests/test_region_emc.lua` (registered)

**Interfaces:**
- Consumes: a `fr:read()` result `est`.
- Produces (pure): `EnginePanel.flowLabel(est)` and `EnginePanel.leftLabel(est)` → display strings per state: drain → `"FLOW 450 mB/m"` / `"LEFT 18m"` (or `"LEFT 1h05m"`); idle → `"FLOW 0 mB/m"` / `"LEFT --"`; refuel → `"FLOW +"` / `"LEFT +"`; unknown → `"FLOW --"` / `"LEFT --"`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_region_emc.lua` (require `ui.panels.engine` as `E`):

```lua
t.test("engine panel: flow/left labels per state", function()
  local E = require("ui.panels.engine")
  t.eq(E.flowLabel({ state="drain", mbPerMin=450 }), "FLOW 450 mB/m", "drain flow")
  t.eq(E.leftLabel({ state="drain", secondsLeft=18*60 }), "LEFT 18m", "drain left <1h")
  t.eq(E.leftLabel({ state="drain", secondsLeft=65*60 }), "LEFT 1h05m", "drain left >=1h zero-pad")
  t.eq(E.flowLabel({ state="idle" }), "FLOW 0 mB/m", "idle flow")
  t.eq(E.leftLabel({ state="idle" }), "LEFT --", "idle left")
  t.eq(E.flowLabel({ state="refuel" }), "FLOW +", "refuel flow")
  t.eq(E.leftLabel({ state="refuel" }), "LEFT +", "refuel left")
  t.eq(E.flowLabel({ state="unknown" }), "FLOW --", "unknown flow")
  t.eq(E.leftLabel(nil), "LEFT --", "nil left")
end)
```

- [ ] **Step 2: Run to verify fail** — FAIL.

- [ ] **Step 3: Implement**

Add to `ui/panels/engine.lua`:

```lua
function M.flowLabel(est)
  local st = est and est.state
  if st == "refuel" then return "FLOW +" end
  if st == "idle" then return "FLOW 0 mB/m" end
  if st == "drain" then return string.format("FLOW %d mB/m", math.floor((est.mbPerMin or 0) + 0.5)) end
  return "FLOW --"
end
function M.leftLabel(est)
  local st = est and est.state
  if st == "refuel" then return "LEFT +" end
  if st == "drain" then
    local s = est.secondsLeft
    if type(s) == "number" and s > 0 then
      local m = math.floor(s / 60)
      if m < 60 then return string.format("LEFT %dm", m) end
      return string.format("LEFT %dh%02dm", math.floor(m / 60), m % 60)
    end
  end
  return "LEFT --"
end
```

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/panels/engine.lua tests/test_region_emc.lua
git commit -m "feat(ui): engine-panel FLOW/LEFT format seam"
```

---

### Task 3: Wire the poll + thread `fuelEst` through `buildState`

**Files:**
- Modify: `ui/basalt/app.lua` (runtime build near `fuelReaders`; poll "(c)"; `M.buildState`)
- Test: `tests/test_basalt_app.lua` (registered) — buildState threading

**Interfaces:**
- Consumes: `ui.fuelrate` (Task 1).
- Produces: `runtime.fuelRate = FuelRate.new(runtime.config.fuel and runtime.config.fuel.rate)`; the 3 s poll calls `runtime.fuelRate:push(runtime.state.tankMb, os.epoch("utc"))` then `runtime.state.fuelEst = runtime.fuelRate:read()`; `M.buildState` returns `fuelEst = runtime.state.fuelEst`.

- [ ] **Step 1: Write the failing test** (buildState threading — the real seam)

Add to `tests/test_basalt_app.lua` (mirror its existing buildState-test harness that builds a fake `runtime`; here `runtime.state.fuelEst` is what matters):

```lua
t.test("buildState threads fuelEst from runtime.state", function()
  local est = { state = "drain", mbPerMin = 450, secondsLeft = 1080 }
  local runtime = <minimal fake runtime per this file's buildState harness, with runtime.state.fuelEst = est>
  local s = M.buildState(runtime, 1000)
  t.eq(s.fuelEst, est, "fuelEst propagated into state")
end)
```

*(Author note: read `tests/test_basalt_app.lua`'s existing buildState test to copy its fake-runtime shape — it must satisfy `rx:latest()`, `engine:status()`, `hbRx:up()`, `runtime.state`, etc. Only add `runtime.state.fuelEst`; assert propagation. This is the exact class of test Part 1's fix-wave added.)*

- [ ] **Step 2: Run to verify fail** — FAIL (`s.fuelEst` nil).

- [ ] **Step 3: Implement**

- Require `FuelRate` at the top of `ui/basalt/app.lua`: `local FuelRate = require("ui.fuelrate")`.
- In the runtime-build function, near `local fuelReaders = {...}`, add: `local fuelRate = FuelRate.new(config.fuel and config.fuel.rate)` and include `fuelRate = fuelRate,` in the returned runtime table.
- In the 3 s poll schedule "(c)", after the two `Fuel.read(...)` assignments, add:

```lua
      runtime.fuelRate:push(runtime.state.tankMb, os.epoch("utc"))
      runtime.state.fuelEst = runtime.fuelRate:read()
```

- In `M.buildState`'s returned table, add (with the other `runtime.state.*` passthroughs like `tankMb`): `fuelEst = runtime.state.fuelEst,`.

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/app.lua tests/test_basalt_app.lua
git commit -m "feat(ui): poll feeds fuelRate; thread fuelEst through buildState"
```

---

### Task 4: `sigFlight` includes the estimate

**Files:**
- Modify: `ui/basalt/renderpolicy.lua` (`M.sigFlight`)
- Test: `tests/test_renderpolicy.lua` (registered)

**Interfaces:**
- Produces: `sigFlight` signature changes when `fuelEst.state` / rounded `fuelEst.mbPerMin` / rounded `fuelEst.secondsLeft` change (so a 3 s estimate change dirties the 250 ms flight gate and `emc_main` repaints).

- [ ] **Step 1: Write the failing test**

Add to `tests/test_renderpolicy.lua`:

```lua
t.test("sigFlight reacts to fuelEst change", function()
  local base = { fuelEst = { state="drain", mbPerMin=450, secondsLeft=1080 } }
  local a = R.sigFlight(base)
  local b = R.sigFlight({ fuelEst = { state="drain", mbPerMin=900, secondsLeft=540 } })
  local c = R.sigFlight({ fuelEst = { state="idle", mbPerMin=0 } })
  t.truthy(a ~= b, "rate change dirties the gate")
  t.truthy(a ~= c, "state change dirties the gate")
  t.eq(R.sigFlight(base), a, "stable when unchanged")
end)
```

- [ ] **Step 2: Run to verify fail** — FAIL.

- [ ] **Step 3: Implement**

In `M.sigFlight`'s `table.concat({...})`, append (matching the file's `tostring`/`qn` style; guard nil `fuelEst`):

```lua
    tostring(state.fuelEst and state.fuelEst.state),
    qn(state.fuelEst and state.fuelEst.mbPerMin, 0),
    qn(state.fuelEst and state.fuelEst.secondsLeft, 0),
```

(`qn` is the file's existing quantized-number helper; if `qn` rejects nil, guard with `and ... or 0`.)

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/renderpolicy.lua tests/test_renderpolicy.lua
git commit -m "feat(ui): sigFlight dirties on fuel estimate change"
```

---

### Task 5: FLOW/LEFT readouts under the tank gauge (`emc_main`)

**Files:**
- Modify: `ui/basalt/regions/emc.lua` (`M.main`)
- Test: `tests/test_region_emc.lua` (registered)

**Interfaces:**
- Consumes: `EnginePanel.flowLabel`/`leftLabel` (Task 2), `state.fuelEst` (Task 3).
- Produces: two readouts on the row directly beneath the Liquid Main tank bar (which is at y5 → place at y6, within the `ix0..ix1` inner width), updated in the region's `apply(state)` from `state.fuelEst`. Existing gauges/buttons/status-box unchanged.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_region_emc.lua` (build `emc_main`; drive its `apply`):

```lua
t.test("emc_main shows FLOW/LEFT from fuelEst", function()
  local built = <build emc_main via this file's region-build helper>
  built.apply({ fuelEst = { state="drain", mbPerMin=450, secondsLeft=18*60 } })
  t.eq(<the FLOW label's text>, "FLOW 450 mB/m", "flow rendered")
  t.eq(<the LEFT label's text>, "LEFT 18m", "left rendered")
  built.apply({ fuelEst = { state="idle" } })
  t.eq(<FLOW text>, "FLOW 0 mB/m", "idle flow"); t.eq(<LEFT text>, "LEFT --", "idle left")
end)
```

*(Author note: read `tests/test_region_emc.lua`'s emc_main build + how it reads label text from the returned `elements`. Expose the two new labels in `elements` (e.g. `elements.flowLabel`, `elements.leftLabel`) so the test can read `:getText()`, consistent with how this region exposes other handles.)*

- [ ] **Step 2: Run to verify fail** — FAIL.

- [ ] **Step 3: Implement**

In `M.main`, after the Liquid Main tank bar (`mainBar` at y5), add two labels on y6 within `ix0..ix1` (split the width: FLOW on the left, LEFT on the right; if the monitor is too narrow for both on one row, stack or abbreviate — read the actual `w`). Require the engine panel as `EnginePanel` if not already. In the region's `apply(state)` set their text:

```lua
  flowLabel:setText(EnginePanel.flowLabel(state and state.fuelEst))
  leftLabel:setText(EnginePanel.leftLabel(state and state.fuelEst))
```

Expose `flowLabel`/`leftLabel` in the returned `elements`. Do NOT disturb the gauges, ENG SW/PRIME, status box, or CONFIG button.

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/regions/emc.lua tests/test_region_emc.lua
git commit -m "feat(ui): FLOW/LEFT fuel-time readouts under the tank gauge"
```

---

### Task 6: Regenerate dist + manifests; dual-suite green

- [ ] **Step 1: Regenerate** — `node tools/build.mjs && bash tools/run_gen.sh`.
- [ ] **Step 2: Run both suites** — `bash tests/run_headless.sh` and `bash tests/run_headless_dist.sh` → BOTH PASS, both "IN SYNC".
- [ ] **Step 3: Commit**

```bash
git add dist manifest.lua manifest-dev.lua
git commit -m "build: dist + manifest for fuel time estimate"
```

---

## Self-Review

**Spec coverage:** §2 module → Task 1. §3 adaptive math → Task 1 (impl + step-up test). §4 wiring (poll/buildState/sigFlight) → Tasks 3/4. §5 knobs → Task 1 defaults + `config.fuel.rate` override (Task 3 passes it). §6 UI (FLOW/LEFT under tank, formats, states) → Tasks 2/5. §7 testing → per-task + Task 6.
- The Part 1 threading lesson (buildState + sigFlight, each tested) is Tasks 3 + 4 — present by construction, not deferred.

**Placeholder scan:** Task 3/5 test snippets carry author-notes pointing at the real fake-runtime / region-build harness to copy (per-file mock shapes differ); impl code + assertions are concrete. No TBD.

**Type consistency:** `fr:read()` → `{state,mbPerMin,secondsLeft}` (Tasks 1/2/3/4/5); `runtime.fuelRate`/`runtime.state.fuelEst` (Task 3); `state.fuelEst` (Tasks 3/4/5); `flowLabel`/`leftLabel` (Tasks 2/5). Consistent.

## Execution Handoff

The user cleared subagent-driven execution. Proceed with superpowers:subagent-driven-development.
