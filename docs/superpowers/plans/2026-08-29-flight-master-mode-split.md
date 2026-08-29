# Flight-mode / Master-mode Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the single 7-entry FCS mode selector into two orthogonal, always-both-active selectors — flight modes (scheme / keymap / effectors) and master modes (CPL/DCPL horizontal drift law) — while fixing DRN and forward-trim to their intended behavior.

**Architecture:** Flight modes drop to five (PRECISION, MAN, CRUISE, LDG, DRN) and keep owning scheme/keymap/caps/policy. Master mode (CPL/DCPL) becomes a tiny runtime state that owns one thing — the hands-off horizontal drift law — plus it gates the always-applied forward trim. MAN's `relaxTiltDrift` and the deleted coupled scheme's `decoupled` idle-zeroing collapse into one per-axis "hold vs. relax" rule in the pilot, parameterized by a `driftArrest` boolean. Forward trim moves out of the pilot's coupled branch into a `demands.pitch += trimDir*trimGain*demands.surge` feedforward in the control loop, so it works in every flight mode.

**Tech Stack:** Lua 5.1 (CC:Tweaked), Basalt 2.0 UI. Headless test suite via `tests/framework.lua` + `bash tests/run_headless.sh`. Build via `node tools/build.mjs` (regenerates `dist/`, `manifest.lua`, `manifest-dev.lua`).

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-29-flight-master-mode-split-design.md`. Every task's requirements implicitly include it.
- **Target:** Minecraft 1.21.1, CC:Tweaked + Basalt 2.0 (full build).
- **No unicode / no em-dash glyphs** in any CC:T-rendered string — ASCII only (`--`, not `—`).
- **No optimistic UI:** buttons/switches reflect only reported telemetry (`state.flightMode` / `state.masterMode` / `state.trimDir`), never the tap.
- **Master mode is ALWAYS set** — there is no "no master" state. Boot default `CPL`.
- **Trim never touches forward thrusters.** It is a pitch-demand feedforward realized as a lift-thruster differential; never MAIN/FRL/FRR.
- **Tests are registered** in the `suites` array in `tests/run_headless.sh`. Adding a test file requires adding its module path there; deleting one requires removing it.
- **Test framework API:** `local t = require("tests.framework")`; `t.test(name, fn)`, `t.eq(a,b,msg)`, `t.near(a,b,tol,msg)`, `t.truthy(v,msg)`.
- **Do NOT hand-edit** `dist/**`, `tests/.craftos/**`, `manifest*.lua` — those are build artifacts regenerated in the final task.
- **Run the suite** with `bash tests/run_headless.sh` from the repo root; expect `NNNN passed, 0 failed`.
- **Commit** after each task with the shown message.

## File Structure

**Core control (fcs/):**
- `fcs/io/tuningdefaults.lua` — MODIFY: add `trimGain`/`climbRampTime`/`climbBoost` to shared `DEFAULTS.feel`; delete `coupledFeel()` + `DEFAULTS.modes.CPL`/`.DCPL`; raise `DEFAULTS.modes.DRN.caps` sway/surge off zero.
- `fcs/modes/master.lua` — CREATE: the master-mode registry (`MASTERS`, `byId` with `driftArrest`, `default`).
- `fcs/modes/registry.lua` — MODIFY: remove CPL/DCPL SPECS + Coupled/Decoupled requires + MAN `relaxTiltDrift` flag.
- `fcs/schemes/coupled.lua`, `fcs/schemes/decoupled.lua` — DELETE.
- `fcs/schemes/drone.lua` — MODIFY: stop zeroing sway/surge.
- `fcs/input/keymap.lua` — MODIFY: delete `M.coupled` + `rudder`/`finesurge` FLAGs; `forMode` recognizes only DRN.
- `fcs/input/pilot.lua` — MODIFY: add `setMaster`; unified hold/relax rule; always-on climb ramp; delete coupled input block + coupled trim sub-block.
- `fcs/runtime/loop.lua` — MODIFY: `setTrim` + trim feedforward in `cycle`.
- `fcs/runtime/flight.lua` — MODIFY: master-mode state/command/snapshot; thread `driftArrest`→pilot and trim→loop; boot default.

**Wiring:**
- `tools/hover_test.lua` — MODIFY: `buildLoop` returns master registry; boot `setTrim`.
- `tools/flight.lua` — MODIFY: pass master default to `Flight.new`; call `pilot:setMaster`.

**UI:**
- `ui/panels/fcs.lua` — MODIFY: `MODES`→5; add `MASTERS`/`MASTER_LABEL`/`masterActive`; `action` handles master ids; `trimActive` keys off `masterMode`.
- `ui/basalt/app.lua` — MODIFY: `buildState` passes `masterMode` through; cadence signature includes it.
- `ui/basalt/pages/fcs.lua` — MODIFY: add master-switch row + apply.
- `ui/basalt/regions/fcs.lua` — MODIFY: add master chips + apply.
- `ui/basalt/bitconfig/tuning.lua` — MODIFY: drop CPL/DCPL `MODE_EXTRA_ROWS`; add `trimGain`/`climbRampTime`/`climbBoost` to the shared base FEEL rows.

**Tests:** delete `test_scheme_coupled.lua`, `test_pilot_coupled.lua`, `test_keymap_coupled.lua`; add `test_modes_master.lua`, `test_loop_trim.lua`, `test_pilot_drift.lua`, `test_flight_master.lua`; update `test_tuning_modes.lua`, `test_modes_registry.lua`, `test_scheme_drone.lua`, `test_keymap.lua`, `test_pilot_modes.lua`, `test_flight.lua`, `test_buildloop_modes.lua`, `test_panels_fcs_modes.lua`, `test_page_fcs.lua`, `test_region_fcs_modes.lua`, `test_ui_flightmode_state.lua`, `test_params.lua`, `test_bitconfig_tuning.lua` as each task requires.

---

### Task 1: Tuning defaults — shared trim/ramp feel, drop coupled records, fix DRN caps

**Files:**
- Modify: `fcs/io/tuningdefaults.lua`
- Test: `tests/test_tuning_modes.lua`, `tests/test_tuningdefaults.lua`

**Interfaces:**
- Produces: `DEFAULTS.feel.trimGain = 0.35`, `DEFAULTS.feel.climbRampTime = 1.0`, `DEFAULTS.feel.climbBoost = 2.0` (every flight mode's feel inherits these). `DEFAULTS.modes.CPL`/`.DCPL` and `coupledFeel()` no longer exist. `DEFAULTS.modes.DRN.caps.sway = 0.9`, `.surge = 1.0`.

- [ ] **Step 1: Write the failing test** — append to `tests/test_tuning_modes.lua`:

```lua
t.test("tuning: trim/ramp feel is shared on the base feel (all flight modes inherit)", function()
  local D = require("fcs.io.tuningdefaults").get()
  t.eq(D.feel.trimGain, 0.35, "base trimGain")
  t.eq(D.feel.climbRampTime, 1.0, "base climbRampTime")
  t.eq(D.feel.climbBoost, 2.0, "base climbBoost")
  -- CPL/DCPL are no longer flight-mode tuning records
  t.eq(D.modes.CPL, nil, "no CPL mode record")
  t.eq(D.modes.DCPL, nil, "no DCPL mode record")
  -- DRN horizontal thrusters have real authority now (loop stabilizes on release)
  t.truthy(D.modes.DRN.caps.sway > 0, "DRN sway cap off zero")
  t.truthy(D.modes.DRN.caps.surge > 0, "DRN surge cap off zero")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh 2>&1 | tail -3`
Expected: FAIL — `base trimGain: expected 0.35 got nil` (trimGain is only under the coupled feel today).

- [ ] **Step 3: Write minimal implementation**

In `fcs/io/tuningdefaults.lua`:

1. Add three keys to `DEFAULTS.feel` (in the `feel = { ... }` literal, after `swayLead = 10.0,`):

```lua
    climbRampTime  = 1.0,   -- lift ramp: hold time to reach full climbBoost (rampable climb, all modes)
    climbBoost     = 2.0,   -- sustained-hold climb rate multiplier (tap = 1x, hold ramps to 1+boost)
    trimGain       = 0.35,  -- forward-trim feedforward gain: demands.pitch += trimDir*trimGain*demands.surge
```

2. Delete the entire `local function coupledFeel() ... end` block and the `DEFAULTS.modes.CPL = { ... }` and `DEFAULTS.modes.DCPL = { ... }` assignments.

3. Change `DEFAULTS.modes.DRN.caps` from `{ ..., sway = 0, surge = 0 }` to:

```lua
  caps  = { pitch = 0.5, roll = 0.5, yaw = DEFAULTS.caps.yaw, sway = DEFAULTS.caps.sway, surge = DEFAULTS.caps.surge },
```

- [ ] **Step 4: Run test to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | tail -3`. Expected: the new case passes. (Other suites may now fail — that is expected; later tasks fix registry/pilot/tuning-editor consumers of the removed records. Note which files fail for cross-checking.)

- [ ] **Step 5: Commit**

```bash
git add fcs/io/tuningdefaults.lua tests/test_tuning_modes.lua
git commit -m "feat(tuning): shared trim/ramp feel; drop CPL/DCPL records; DRN caps off zero"
```

---

### Task 2: Master-mode registry module

**Files:**
- Create: `fcs/modes/master.lua`
- Create test: `tests/test_modes_master.lua`
- Modify: `tests/run_headless.sh` (register the new test)

**Interfaces:**
- Produces: `require("fcs.modes.master")` → `{ MASTERS = {"CPL","DCPL"}, default = "CPL", byId = { CPL = { id="CPL", driftArrest=true }, DCPL = { id="DCPL", driftArrest=false } } }`. `driftArrest=true` means hold station when hands-off; `false` means coast.

- [ ] **Step 1: Write the failing test** — create `tests/test_modes_master.lua`:

```lua
-- tests/test_modes_master.lua
local t = require("tests.framework")
local Master = require("fcs.modes.master")

t.test("master registry: CPL arrests drift, DCPL coasts, default CPL", function()
  t.eq(Master.default, "CPL", "default master")
  t.eq(#Master.MASTERS, 2, "two masters")
  t.eq(Master.MASTERS[1], "CPL", "order CPL first")
  t.eq(Master.MASTERS[2], "DCPL", "order DCPL second")
  t.eq(Master.byId.CPL.driftArrest, true, "CPL arrests")
  t.eq(Master.byId.DCPL.driftArrest, false, "DCPL coasts")
  t.eq(Master.byId.CPL.id, "CPL", "id carried")
end)
```

- [ ] **Step 2: Register + run to verify it fails** — In `tests/run_headless.sh`, add `"tests.test_modes_master"` to the `suites` array (near `"tests.test_modes_registry"`). Run: `bash tests/run_headless.sh 2>&1 | tail -3`. Expected: FAIL — `module 'fcs.modes.master' not found`.

- [ ] **Step 3: Write minimal implementation** — create `fcs/modes/master.lua`:

```lua
-- fcs/modes/master.lua -- the master-mode registry. Master mode is orthogonal to flight mode:
-- exactly one is always active. It owns ONE thing -- the hands-off horizontal drift law --
-- exposed as driftArrest (CPL = hold station / arrest residual velocity; DCPL = coast). It also
-- gates the always-applied forward trim (see fcs/runtime/loop.lua), identical in both modes.
local M = {
  MASTERS = { "CPL", "DCPL" },
  default = "CPL",
  byId = {
    CPL  = { id = "CPL",  driftArrest = true  },
    DCPL = { id = "DCPL", driftArrest = false },
  },
}
return M
```

- [ ] **Step 4: Run test to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "test_modes_master|passed"`. Expected: the master case passes.

- [ ] **Step 5: Commit**

```bash
git add fcs/modes/master.lua tests/test_modes_master.lua tests/run_headless.sh
git commit -m "feat(modes): master-mode registry (CPL/DCPL driftArrest)"
```

---

### Task 3: Flight-mode registry — drop CPL/DCPL, delete coupled schemes

**Files:**
- Modify: `fcs/modes/registry.lua`
- Delete: `fcs/schemes/coupled.lua`, `fcs/schemes/decoupled.lua`, `tests/test_scheme_coupled.lua`
- Modify: `fcs/modes/registry.lua` test `tests/test_modes_registry.lua`; `tests/run_headless.sh` (unregister `test_scheme_coupled`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Registry.build(tuning).order == {"PRECISION","MAN","CRUISE","LDG","DRN"}`, `byId.CPL == nil`, `byId.DCPL == nil`, `default == "LDG"`. MAN's policy no longer carries `relaxTiltDrift`.

- [ ] **Step 1: Write the failing test** — replace CPL/DCPL assertions in `tests/test_modes_registry.lua` (find any `byId.CPL`/`"CPL"` expectations) and add:

```lua
t.test("registry: five flight modes, no CPL/DCPL, MAN has no relaxTiltDrift flag", function()
  local reg = require("fcs.modes.registry").build(require("fcs.tuning"))
  t.eq(#reg.order, 5, "five flight modes")
  t.eq(reg.byId.CPL, nil, "CPL removed")
  t.eq(reg.byId.DCPL, nil, "DCPL removed")
  t.eq(reg.default, "LDG", "boot default LDG")
  t.eq(reg.byId.MAN.policy.relaxTiltDrift, nil, "MAN relaxTiltDrift flag gone (generalized in pilot)")
  t.truthy(reg.byId.MAN.policy.tilt, "MAN still tilts")
  t.eq(reg.byId.DRN.policy.translate, false, "DRN keeps translate=false (no direct translate keys)")
end)
```

- [ ] **Step 2: Run to verify it fails** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "five flight modes|FAIL tests.test_modes_registry"`. Expected: FAIL — `five flight modes: expected 5 got 7`.

- [ ] **Step 3: Write minimal implementation** — In `fcs/modes/registry.lua`:

1. Delete the two lines `local Coupled = require("fcs.schemes.coupled")` and `local Decoupled = require("fcs.schemes.decoupled")`.
2. In `SPECS`, delete the `CPL` and `DCPL` rows, and remove `relaxTiltDrift = true` from the MAN row. The SPECS table becomes:

```lua
local SPECS = {
  { id = "PRECISION", label = "PRECISION", ctor = Level,   policy = { tilt = false, surge = "position" } },
  { id = "MAN",       label = "MAN",       ctor = Manual,  policy = { tilt = true,  surge = "position" } },
  { id = "CRUISE",    label = "CRUISE",    ctor = Cruise,  policy = { tilt = false, surge = "throttle" } },
  { id = "LDG",       label = "LDG",       ctor = Level,   policy = { tilt = false, surge = "position" },
                      groundSense = true, canPark = true },
  { id = "DRN",       label = "DRN",       ctor = Drone,   policy = { tilt = true,  surge = "position", translate = false } },
}
```

3. Delete files `fcs/schemes/coupled.lua` and `fcs/schemes/decoupled.lua`.
4. Delete `tests/test_scheme_coupled.lua` and remove `"tests.test_scheme_coupled"` from the `suites` array in `tests/run_headless.sh`.

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "five flight modes|passed"`. Expected: the registry case passes. (Pilot/keymap suites may still fail — fixed in later tasks.)

- [ ] **Step 5: Commit**

```bash
git add fcs/modes/registry.lua tests/test_modes_registry.lua tests/run_headless.sh
git rm fcs/schemes/coupled.lua fcs/schemes/decoupled.lua tests/test_scheme_coupled.lua
git commit -m "feat(modes): registry drops CPL/DCPL flight modes; delete coupled schemes"
```

---

### Task 4: Drone scheme — stop zeroing horizontal thrusters

**Files:**
- Modify: `fcs/schemes/drone.lua`
- Test: `tests/test_scheme_drone.lua`

**Interfaces:**
- Produces: `Drone:update` now returns the inner Level translate loop's `sway`/`surge` demands unchanged (the horizontal loop runs; the master law + pilot keymap decide the setpoints upstream).

- [ ] **Step 1: Rewrite the failing test** — replace the body of `tests/test_scheme_drone.lua`:

```lua
-- tests/test_scheme_drone.lua
local t = require("tests.framework")
local Drone = require("fcs.schemes.drone")

t.test("DRN: attitude/alt pass through AND horizontal loop stabilizes a position error", function()
  local d = Drone.new({ hoverDuty = 0.26, alt = {}, pitch = {}, roll = {}, yaw = {},
                        sway = { kp = 0.2 }, surge = { kp = 0.15 } })
  local sp = { pitch = 0.1, roll = -0.1, heading = 0, altitude = 5, swayPos = 10, surgePos = 10 }
  local m  = { pitch = 0, roll = 0, heading = 0, altitude = 5, swayPos = 0, surgePos = 0,
              swayVel = 0, surgeVel = 0, yawRate = 0 }
  local out = d:update(sp, m, 0.05, false, nil)
  -- horizontal error present -> the FCS commands a correction now (was forced to 0 before)
  t.truthy(out.sway ~= 0, "sway loop stabilizes (not forced 0)")
  t.truthy(out.surge ~= 0, "surge loop stabilizes (not forced 0)")
  t.truthy(out.pitch ~= nil and out.roll ~= nil, "attitude demands present")
  t.truthy(d.pitchPid ~= nil and d.rollPid ~= nil, "inner pids exposed for comAuto")
end)
```

- [ ] **Step 2: Run to verify it fails** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "sway loop stabilizes|FAIL tests.test_scheme_drone"`. Expected: FAIL — `sway loop stabilizes (not forced 0): got 0`.

- [ ] **Step 3: Write minimal implementation** — In `fcs/schemes/drone.lua`, delete the line `d.sway, d.surge = 0, 0` and its comment; update the header comment. The `update` becomes:

```lua
function Drone:update(sp, m, dt, freeze, sat)
  -- Full Level loop: attitude/heading/altitude hold AND the horizontal translate loop, which
  -- stabilizes on release. The drone KEYMAP (no translate keys) and the pilot's relax-while-
  -- tilting + master drift law decide the horizontal setpoints; the scheme no longer forces 0.
  return self.inner:update(sp, m, dt, freeze, sat)
end
```

(Keep `Drone.new` exposing `pitchPid`/`rollPid`.)

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "sway loop stabilizes|passed"`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add fcs/schemes/drone.lua tests/test_scheme_drone.lua
git commit -m "fix(scheme): DRN keeps FCS horizontal stabilization (drop forced sway/surge=0)"
```

---

### Task 5: Keymap — remove the coupled layout

**Files:**
- Modify: `fcs/input/keymap.lua`
- Delete: `tests/test_keymap_coupled.lua`
- Modify: `tests/test_keymap.lua`; `tests/run_headless.sh` (unregister `test_keymap_coupled`)

**Interfaces:**
- Produces: `keymap.forMode(id)` returns `M.drone` for `"DRN"`, `M.default` for everything else (including `"CPL"`/`"DCPL"` — harmless, they are never flight-mode ids now). `M.coupled` no longer exists.

- [ ] **Step 1: Write the failing test** — add to `tests/test_keymap.lua`:

```lua
t.test("keymap.forMode: only DRN diverges; coupled layout removed", function()
  local km = require("fcs.input.keymap")
  t.eq(km.coupled, nil, "M.coupled removed")
  t.eq(km.forMode("DRN"), km.drone, "DRN -> drone layout")
  t.eq(km.forMode("PRECISION"), km.default, "PRECISION -> default")
  t.eq(km.forMode("MAN"), km.default, "MAN -> default")
  t.eq(km.forMode("CRUISE"), km.default, "CRUISE -> default")
  t.eq(km.forMode("LDG"), km.default, "LDG -> default")
end)
```

- [ ] **Step 2: Run to verify it fails** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "M.coupled removed|FAIL tests.test_keymap\b"`. Expected: FAIL — `M.coupled removed: got table`.

- [ ] **Step 3: Write minimal implementation** — In `fcs/input/keymap.lua`:

1. Delete the `finesurge = {...}` and `rudder = {...}` entries from the `FLAG` table.
2. Delete the entire `M.coupled = { ... }` table and its comment.
3. Rewrite `forMode`:

```lua
function M.forMode(id)
  if id == "DRN" then return M.drone end
  return M.default
end
```

4. Delete `tests/test_keymap_coupled.lua` and remove `"tests.test_keymap_coupled"` from `tests/run_headless.sh`.

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "coupled layout removed|passed"`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add fcs/input/keymap.lua tests/test_keymap.lua tests/run_headless.sh
git rm tests/test_keymap_coupled.lua
git commit -m "feat(keymap): remove coupled layout; forMode diverges only for DRN"
```

---

### Task 6: Pilot — master-aware unified hold/relax rule, always-on climb ramp

**Files:**
- Modify: `fcs/input/pilot.lua`
- Delete: `tests/test_pilot_coupled.lua`
- Create test: `tests/test_pilot_drift.lua`
- Modify: `tests/test_pilot_modes.lua`; `tests/run_headless.sh`

**Interfaces:**
- Consumes: flight `policy` (`tilt`, `translate`, `surge`) via existing `setMode`; new `Pilot:setMaster(driftArrest)`.
- Produces: `Pilot:setMaster(driftArrest)` sets `self.driftArrest`. `Pilot:update` applies the per-axis rule: while a tilt key is held (and `policy.tilt`), OR when `driftArrest` is false and that axis is not being directly translated, the horizontal setpoint (`sp.swayPos`/`sp.surgePos`) is snapped to measured (relax); otherwise the existing leash (follow/hold) stands. Climb ramp applies unconditionally. The coupled input block, `surgeCmd/surgeActive/swayCmd/swayActive/yawRear`, and the coupled pitch-trim sub-block are removed.

- [ ] **Step 1: Write the failing tests** — create `tests/test_pilot_drift.lua`:

```lua
-- tests/test_pilot_drift.lua
local t = require("tests.framework")
local Pilot = require("fcs.input.pilot")

local function feel()
  return { headingRate = 2.2, leadCapHeading = 0.45, yawStopLead = 0.15, climbRate = 4.5,
           leadCapVert = 8.0, surgeSpeed = 10.0, surgeLead = 20.0, swaySpeed = 5.0, swayLead = 10.0,
           climbRampTime = 1.0, climbBoost = 2.0, trimGain = 0.35 }
end
local function meas() return { altitude = 0, heading = 0, swayPos = 3, surgePos = 4,
  swayVel = 0, surgeVel = 0, yawRate = 0 } end

t.test("CPL hands-off holds station; DCPL hands-off relaxes to measured (coast)", function()
  -- CPL: driftArrest true. Setpoint frozen away from measured stays put (loop will drive to it).
  local p = Pilot.new(feel()); p:setMode({ tilt = false, surge = "position" }, feel()); p:setMaster(true)
  p.sp.swayPos, p.sp.surgePos = 0, 0     -- a standing hold target != measured (3,4)
  local sp = p:update(0.05, {}, meas())
  t.eq(sp.swayPos, 0, "CPL holds sway setpoint")
  t.eq(sp.surgePos, 0, "CPL holds surge setpoint")
  -- DCPL: driftArrest false. Hands-off snaps setpoint to measured -> zero error -> coast.
  local q = Pilot.new(feel()); q:setMode({ tilt = false, surge = "position" }, feel()); q:setMaster(false)
  q.sp.swayPos, q.sp.surgePos = 0, 0
  local sq = q:update(0.05, {}, meas())
  t.eq(sq.swayPos, 3, "DCPL relaxes sway to measured")
  t.eq(sq.surgePos, 4, "DCPL relaxes surge to measured")
end)

t.test("tilting relaxes horizontal hold under CPL (generalized relaxTiltDrift), any tilt mode", function()
  local p = Pilot.new(feel()); p:setMode({ tilt = true, surge = "position" }, feel()); p:setMaster(true)
  p.sp.swayPos, p.sp.surgePos = 0, 0
  local sp = p:update(0.05, { pitchUp = true }, meas())   -- actively tilting
  t.eq(sp.swayPos, 3, "tilt relaxes sway to measured")
  t.eq(sp.surgePos, 4, "tilt relaxes surge to measured")
end)

t.test("climb ramp is always on: sustained hold exceeds a single-tick nudge", function()
  local p = Pilot.new(feel()); p:setMode({ tilt = false, surge = "position" }, feel()); p:setMaster(true)
  local m = meas()
  local tap = Pilot.new(feel()); tap:setMode({ tilt = false, surge = "position" }, feel()); tap:setMaster(true)
  local a1 = tap:update(0.05, { up = true }, m).altitude       -- first tick (tap)
  -- hold for ~1s of ramp on a fresh pilot
  local held = 0
  for _ = 1, 20 do held = p:update(0.05, { up = true }, m).altitude end
  t.truthy((held - m.altitude) > (a1 - m.altitude), "ramped climb outpaces the first-tick nudge")
end)
```

- [ ] **Step 2: Register + run to verify it fails** — Add `"tests.test_pilot_drift"` to `tests/run_headless.sh`. Run: `bash tests/run_headless.sh 2>&1 | grep -E "DCPL relaxes|setMaster|FAIL tests.test_pilot_drift"`. Expected: FAIL — `attempt to call method 'setMaster' (a nil value)`.

- [ ] **Step 3: Write minimal implementation** — In `fcs/input/pilot.lua`:

1. In `Pilot.new`, add `driftArrest = true,` to the returned table.
2. Add the setter (near `setMode`):

```lua
function Pilot:setMaster(driftArrest) self.driftArrest = driftArrest ~= false end
```

3. **Climb ramp always-on:** delete the `if self.policy.surge == "coupled" then ... else self.climbHeld = 0 end` wrapper around the ramp and run it unconditionally:

```lua
  local ld = dirOf(held, "down", "up")
  local climbRate = c.climbRate
  if ld ~= 0 then
    self.climbHeld = (self.climbHeld or 0) + dt
    local ramp = math.min(1, self.climbHeld / (c.climbRampTime or 1.0))
    climbRate = c.climbRate * (1 + (c.climbBoost or 0) * ramp)
  else
    self.climbHeld = 0
  end
```

4. **Delete the coupled input block** entirely — the whole `if self.policy.surge == "coupled" then ... end` section (throttle/brake/fine surge/strafe/rudder, producing `sp.surgeCmd/surgeActive/swayCmd/swayActive/yawRear`).

5. **Replace the `relaxTiltDrift` block** with the unified rule. Delete the `if self.policy.relaxTiltDrift then ... end` block and, immediately after the translate-leash block (the `if self.policy.translate ~= false then ... end` section), insert:

```lua
  -- Unified horizontal drift rule (master mode). "relax" = snap the position setpoint to measured
  -- so the translate loop applies no corrective force. Per axis: relax while the pilot tilts to
  -- steer (any tilt mode -- generalizes MAN's old relaxTiltDrift, and gives DRN its "hold altitude,
  -- don't fight the tilt" feel), OR under DCPL (driftArrest=false) whenever that axis is not being
  -- directly translated (momentum coasts). CPL hands-off leaves the leash's held setpoint in place
  -- (arrest drift). DRN has translate=false so it never "directly translates".
  local tilting = self.policy.tilt and
    (held.pitchUp or held.pitchDown or held.rollLeft or held.rollRight) and true or false
  local canTranslate = self.policy.translate ~= false
  local swayCmd  = canTranslate and (held.swayLeft or held.swayRight)  or false
  local surgeCmd = canTranslate and (held.surgeFwd or held.surgeBack)  or false
  if tilting or (not self.driftArrest and not swayCmd)  then sp.swayPos  = meas.swayPos  end
  if tilting or (not self.driftArrest and not surgeCmd) then sp.surgePos = meas.surgePos end
```

6. **Delete the coupled pitch-trim sub-block:** in the `if self.policy.tilt then ... end` section, remove the `if self.policy.surge == "coupled" then ... else ... end` split so it is just:

```lua
    self.tilt.pitch = toward(self.tilt.pitch, dirOf(held, "pitchDown", "pitchUp"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    self.tilt.roll  = toward(self.tilt.roll,  dirOf(held, "rollLeft",  "rollRight"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    sp.pitch, sp.roll = self.tilt.pitch, self.tilt.roll
```

(The `setTrimDir`/`self.throttle` fields are no longer read here; leave `setTrimDir` in place — it is harmless and still called by Flight, but the pitch trim itself now lives in the loop.)

7. Delete `tests/test_pilot_coupled.lua`, remove `"tests.test_pilot_coupled"` from `tests/run_headless.sh`, and in `tests/test_pilot_modes.lua` remove/adjust any case that asserts coupled-only behavior (`surgeCmd`, `yawRear`, `relaxTiltDrift`) — replace expectations with the unified-rule behavior if the case is about horizontal hold.

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "DCPL relaxes|ramped climb|passed"`. Expected: the `test_pilot_drift` cases pass.

- [ ] **Step 5: Commit**

```bash
git add fcs/input/pilot.lua tests/test_pilot_drift.lua tests/test_pilot_modes.lua tests/run_headless.sh
git rm tests/test_pilot_coupled.lua
git commit -m "feat(pilot): unified master drift rule + always-on climb ramp; drop coupled input"
```

---

### Task 7: Loop — forward-trim pitch feedforward

**Files:**
- Modify: `fcs/runtime/loop.lua`
- Create test: `tests/test_loop_trim.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: `demands.surge` from the active scheme.
- Produces: `Loop:setTrim(dir, gain)` stores `self.trimDir`, `self.trimGain`. In `cycle`, immediately after `scheme:update` and before the oscillation/DAMPED block, `demands.pitch = demands.pitch + (self.trimDir or 0)*(self.trimGain or 0)*(demands.surge or 0)`. Trim is never applied when disarmed (early return) or DAMPED (that block zeroes pitch after). Only `demands.pitch` changes — MAIN/surge duties are untouched.

- [ ] **Step 1: Write the failing test** — create `tests/test_loop_trim.lua`:

```lua
-- tests/test_loop_trim.lua
local t = require("tests.framework")
local Loop = require("fcs.runtime.loop")

-- Minimal fakes: a scheme returning fixed demands, a mixer echoing demands, a no-op backend.
local function fakeScheme(demands)
  return { reset = function() end, update = function() 
    local o = {} for k,v in pairs(demands) do o[k]=v end return o end }
end
local function fakeMixer() return { mix = function(_, d) return d end } end
local function fakeBackend() return { sensors = function() return { onGround = false } end } end
local function fakePwm() return { apply = function() end } end

t.test("loop trim: demands.pitch += trimDir*trimGain*demands.surge; surge untouched", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.5, pitch = 0.1, roll = 0, yaw = 0, sway = 0, surge = 0.8 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0.35)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false })
  t.near(r.demands.pitch, 0.1 + (-1) * 0.35 * 0.8, 1e-9, "nose-down trim added to pitch")
  t.eq(r.demands.surge, 0.8, "surge demand unchanged (no braking)")
end)

t.test("loop trim: zero gain is a no-op", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.5, pitch = 0.1, surge = 0.8 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0); lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false })
  t.near(r.demands.pitch, 0.1, 1e-9, "no trim when gain 0")
end)
```

- [ ] **Step 2: Register + run to verify it fails** — Add `"tests.test_loop_trim"` to `tests/run_headless.sh`. Run: `bash tests/run_headless.sh 2>&1 | grep -E "nose-down trim added|setTrim|FAIL tests.test_loop_trim"`. Expected: FAIL — `attempt to call method 'setTrim' (a nil value)`.

- [ ] **Step 3: Write minimal implementation** — In `fcs/runtime/loop.lua`:

1. Add the setter after `Loop:arm`:

```lua
function Loop:setTrim(dir, gain) self.trimDir = dir or 0; self.trimGain = gain or 0 end
```

2. In `Loop:cycle`, right after the line `local demands = self.scheme:update(self.sp, m, dt, grounded, self._sat)` and before the oscillation `tripped` line, insert:

```lua
  -- Forward trim (master-mode feedforward): the craft pitches nose-up under forward thrust because
  -- its CoM is not vertically centered. Bias the pitch DEMAND (realized as a lift-thruster
  -- differential by the mixer -- never the forward thrusters) proportional to the forward thrust
  -- demand, so the craft holds its intended pitch during acceleration. Applied before the DAMPED
  -- block so a genuine oscillation trip still zeroes it.
  demands.pitch = (demands.pitch or 0) + (self.trimDir or 0) * (self.trimGain or 0) * (demands.surge or 0)
```

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "nose-down trim added|no trim when gain 0|passed"`. Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/loop.lua tests/test_loop_trim.lua tests/run_headless.sh
git commit -m "feat(loop): forward-trim pitch feedforward from surge demand (lift differential)"
```

---

### Task 8: Flight runtime — master-mode state, command, snapshot, threading

**Files:**
- Modify: `fcs/runtime/flight.lua`
- Create test: `tests/test_flight_master.lua`
- Modify: `tests/test_flight.lua`; `tests/run_headless.sh`

**Interfaces:**
- Consumes: `fcs.modes.master`; `pilot:setMaster(bool)`; `loop:setTrim(dir, gain)`; the active descriptor's `feel.trimGain`.
- Produces: `Flight` holds `self.masterMode` (default `Master.default`) and `self.trimGain` (from the default descriptor's feel). `handleCommand{ k="masterMode", id=... }` sets `masterMode` + calls `pilot:setMaster(Master.byId[id].driftArrest)` (unknown id ignored). `flightMode` switch updates `self.trimGain` from `d.feel.trimGain` and re-pushes trim. `flightTrim` re-pushes trim. `snapshot` gains `masterMode = self.masterMode`. `step` pushes `loop:setTrim(self.trimDir, self.trimGain)` each cycle.

- [ ] **Step 1: Write the failing tests** — create `tests/test_flight_master.lua`. (Follow the existing `tests/test_flight.lua` construction of `Flight.new` — reuse its fake loop/pilot/registry helper shape; the assertions below only need `handleCommand`/`snapshot`.)

```lua
-- tests/test_flight_master.lua
local t = require("tests.framework")
local Flight = require("fcs.runtime.flight")

local function fakePilot() return { calls = {},
  setMode = function() end, setPositionHold = function() end, reset = function() end,
  setTrimDir = function() end,
  setMaster = function(self, v) self.calls[#self.calls+1] = v end } end
local function fakeLoop() return { trims = {}, sp = nil,
  setActive = function() end, arm = function() end, setpoints = function() end,
  clearDamped = function() end, getMode = function() return "NORMAL" end,
  cycle = function() return { mode = "NORMAL", m = {} } end,
  setTrim = function(self, d, g) self.trims[#self.trims+1] = { d, g } end } end
local function reg()
  return { default = "LDG", order = { "LDG" },
    byId = { LDG = { id = "LDG", policy = {}, feel = { trimGain = 0.35, trimDir = -1 }, caps = {} } } }
end

t.test("flight: default master CPL; masterMode command sets driftArrest via pilot", function()
  local pilot = fakePilot()
  local f = Flight.new({ loop = fakeLoop(), pilot = pilot, registry = reg() })
  t.eq(f.masterMode, "CPL", "boot master CPL")
  t.truthy(f:handleCommand({ k = "masterMode", id = "DCPL" }), "command handled")
  t.eq(f.masterMode, "DCPL", "master switched to DCPL")
  t.eq(pilot.calls[#pilot.calls], false, "pilot told driftArrest=false for DCPL")
  f:handleCommand({ k = "masterMode", id = "CPL" })
  t.eq(pilot.calls[#pilot.calls], true, "pilot told driftArrest=true for CPL")
  f:handleCommand({ k = "masterMode", id = "BOGUS" })
  t.eq(f.masterMode, "CPL", "unknown master id ignored")
end)

t.test("flight: snapshot reports masterMode", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = fakePilot(), registry = reg() })
  local snap = f:snapshot(nil, {})
  t.eq(snap.masterMode, "CPL", "masterMode on snapshot")
end)
```

- [ ] **Step 2: Register + run to verify it fails** — Add `"tests.test_flight_master"` to `tests/run_headless.sh`. Run: `bash tests/run_headless.sh 2>&1 | grep -E "boot master CPL|FAIL tests.test_flight_master"`. Expected: FAIL — `boot master CPL: expected CPL got nil`.

- [ ] **Step 3: Write minimal implementation** — In `fcs/runtime/flight.lua`:

1. Add `local Master = require("fcs.modes.master")` near the top requires.
2. In `Flight.new`, add to the returned table:

```lua
    masterMode = (deps.masterDefault) or Master.default,
    trimGain = (function()
      local d = deps.registry and deps.registry.byId and deps.registry.default
        and deps.registry.byId[deps.registry.default]
      return (d and d.feel and d.feel.trimGain) or 0
    end)(),
```

3. Add a helper method (after `Flight.new`) that pushes trim to the loop, and call it after boot state is built is not possible inside `new`; instead push in `step` (below) and on trim/mode changes:

4. In `handleCommand`, add a `masterMode` branch (place it beside the `flightMode` branch):

```lua
  elseif k == "masterMode" then
    local d = Master.byId[cmd.id]
    if not d then return true end
    self.masterMode = cmd.id
    if self.pilot.setMaster then self.pilot:setMaster(d.driftArrest) end
    return true
```

5. In the existing `flightMode` branch, after `self.trimDir = (d.feel and d.feel.trimDir) or self.trimDir`, add:

```lua
    self.trimGain = (d.feel and d.feel.trimGain) or self.trimGain
    if self.loop.setTrim then self.loop:setTrim(self.trimDir, self.trimGain) end
```

6. In the existing `flightTrim` branch, after setting `self.trimDir`, add:

```lua
    if self.loop.setTrim then self.loop:setTrim(self.trimDir, self.trimGain) end
```

7. In `Flight:step`, immediately before `local r = self.loop:cycle(dt, meas)`, add:

```lua
  if self.loop.setTrim then self.loop:setTrim(self.trimDir, self.trimGain) end
```

8. In `Flight:snapshot`, add `masterMode = self.masterMode,` to the `snap` table (beside `flightMode = self.flightMode,`).

9. In `tests/test_flight.lua`, if any fake `loop` lacks `setTrim` or fake `pilot` lacks `setMaster`, add no-op stubs so existing cases still construct (the new `step`/`handleCommand` calls guard with `if self.loop.setTrim`/`if self.pilot.setMaster`, so plain fakes stay safe; add stubs only where a case exercises those paths).

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "boot master CPL|masterMode on snapshot|passed"`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/flight.lua tests/test_flight_master.lua tests/test_flight.lua tests/run_headless.sh
git commit -m "feat(fcs): master-mode state/command/snapshot; thread driftArrest + trim"
```

---

### Task 9: Bringup wiring — boot the master mode and trim

**Files:**
- Modify: `tools/hover_test.lua`, `tools/flight.lua`
- Test: `tests/test_buildloop_modes.lua`

**Interfaces:**
- Consumes: `fcs.modes.master`.
- Produces: at boot the pilot's master is set (`pilot:setMaster(true)` for default CPL) and the loop's trim is seeded (`loop:setTrim(defaultTrimDir, defaultFeel.trimGain)`). `Flight.new` still works with the default `masterMode`.

- [ ] **Step 1: Write/adjust the failing test** — in `tests/test_buildloop_modes.lua`, add:

```lua
t.test("buildLoop: registry has five flight modes and no CPL/DCPL", function()
  local hover = require("tools.hover_test")
  -- buildLoop needs a backend; reuse the test's existing fake backend helper if present,
  -- else a minimal one:
  local backend = { sensors = function() return { onGround = false } end,
    liftIds = function() return {} end, lateralIds = function() return {} end,
    mainIds = function() return {} end, frontalIds = function() return {} end }
  local _, reg = hover.buildLoop(backend)
  t.eq(#reg.order, 5, "five flight modes from buildLoop")
  t.eq(reg.byId.CPL, nil, "no CPL")
end)
```

(If `tests/test_buildloop_modes.lua` already builds a backend, reuse that; keep this case consistent with the file's existing helpers.)

- [ ] **Step 2: Run to verify it fails/passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "five flight modes from buildLoop|FAIL tests.test_buildloop_modes"`. Expected: PASS already if Task 3 landed (registry is the source of truth); if the file asserted 7 modes elsewhere, fix those stale numbers now.

- [ ] **Step 3: Wire the runtime** — In `tools/flight.lua`:

1. After `pilot:setMode(registry.byId[registry.default].policy, registry.byId[registry.default].feel)` (around line 67), add:

```lua
local Master = require("fcs.modes.master")
pilot:setMaster(Master.byId[Master.default].driftArrest)
```

2. Seed the loop trim once after `Flight.new(...)` is constructed (the flight object owns `trimDir`/`trimGain`):

```lua
loop:setTrim(flight.trimDir, flight.trimGain)
```

In `tools/hover_test.lua` `buildLoop`, no functional change is required (it already returns `loop, reg`); if the file constructs a pilot for standalone runs, mirror the `setMaster` call there.

- [ ] **Step 4: Run the full suite** — Run: `bash tests/run_headless.sh 2>&1 | tail -3`. Expected: `NNNN passed, 0 failed` for the fcs/core layers (UI suites still to be fixed in Tasks 10-14 may fail — note them).

- [ ] **Step 5: Commit**

```bash
git add tools/flight.lua tools/hover_test.lua tests/test_buildloop_modes.lua
git commit -m "feat(bringup): boot master mode + seed loop trim"
```

---

### Task 10: UI panel logic — flight/master selectors in ui/panels/fcs.lua

**Files:**
- Modify: `ui/panels/fcs.lua`
- Test: `tests/test_panels_fcs_modes.lua`

**Interfaces:**
- Produces: `M.MODES = {"PRECISION","MAN","CRUISE","LDG","DRN"}`; `M.MASTERS = {"CPL","DCPL"}`; `M.MASTER_LABEL = { CPL="CPL", DCPL="DCPL" }`; `M.masterActive(ctx, id)` true iff `ctx.masterMode == id`; `M.action(id)` returns `{ k = "masterMode", id = id }` for a master id (and still `{ k = "flightMode", id = id }` for a flight id); `M.trimActive(ctx)` true iff `ctx.masterMode == "CPL" or "DCPL"`.

- [ ] **Step 1: Write the failing test** — in `tests/test_panels_fcs_modes.lua`, add and adjust any 7-mode expectation to 5:

```lua
t.test("panels/fcs: split selectors -- 5 flight modes, 2 master modes", function()
  local F = require("ui.panels.fcs")
  t.eq(#F.MODES, 5, "five flight modes")
  local set = {} for _, id in ipairs(F.MODES) do set[id] = true end
  t.truthy(not set.CPL and not set.DCPL, "CPL/DCPL not flight modes")
  t.eq(#F.MASTERS, 2, "two master modes")
  t.eq(F.action("DCPL").k, "masterMode", "master id -> masterMode command")
  t.eq(F.action("DCPL").id, "DCPL", "master id carried")
  t.eq(F.action("PRECISION").k, "flightMode", "flight id -> flightMode command")
  t.truthy(F.masterActive({ masterMode = "CPL" }, "CPL"), "masterActive reads masterMode")
  t.truthy(not F.masterActive({ masterMode = "CPL" }, "DCPL"), "masterActive exclusive")
  t.truthy(F.trimActive({ masterMode = "DCPL" }), "trim active with a master set")
  t.truthy(not F.trimActive({}), "trim inactive with no reported master yet")
end)
```

- [ ] **Step 2: Run to verify it fails** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "five flight modes|FAIL tests.test_panels_fcs_modes"`. Expected: FAIL — `five flight modes: expected 5 got 7`.

- [ ] **Step 3: Write minimal implementation** — In `ui/panels/fcs.lua`:

1. `M.MODES = { "PRECISION", "MAN", "CRUISE", "LDG", "DRN" }`.
2. `M.MODE_LABEL` — drop the `CPL`/`DCPL` keys (leave PRE/MAN/CRU/LDG/DRN).
3. Add after the flight-mode block:

```lua
M.MASTERS = { "CPL", "DCPL" }
M.MASTER_LABEL = { CPL = "CPL", DCPL = "DCPL" }
local MASTER_SET = {}
for _, id in ipairs(M.MASTERS) do MASTER_SET[id] = true end

function M.masterActive(ctx, id)
  return (ctx and ctx.masterMode) == id
end
```

4. Update `MODE_SET` rebuild — it is built from `M.MODES`, so it now naturally excludes CPL/DCPL. In `M.action`, add master handling before the flight `MODE_SET` check is fine, but keep flight first; add:

```lua
  if MASTER_SET[id] then
    return { k = "masterMode", id = id }
  end
```

(place it right after the `if MODE_SET[id] then return { k = "flightMode", id = id } end` block).

5. Rewrite `M.trimActive`:

```lua
function M.trimActive(ctx)  -- trim is a master-mode capability; a master is always set once telemetry arrives
  return ctx and (ctx.masterMode == "CPL" or ctx.masterMode == "DCPL")
end
```

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "split selectors|passed"`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add ui/panels/fcs.lua tests/test_panels_fcs_modes.lua
git commit -m "feat(ui): panels/fcs split flight/master selectors + master-gated trim"
```

---

### Task 11: buildState — carry masterMode to the cockpit

**Files:**
- Modify: `ui/basalt/app.lua`
- Test: `tests/test_params.lua` (or `tests/test_basalt_app.lua` — whichever exercises `buildState`)

**Interfaces:**
- Consumes: `latest.masterMode` from FCS telemetry.
- Produces: `buildState` output carries `masterMode = latest.masterMode`; the cadence signature (`ui/basalt/cadence.lua`) includes it so the FCS page repaints when the master mode changes.

- [ ] **Step 1: Write the failing test** — add to the file that unit-tests `buildState` (search: `grep -rn "buildState" tests/`):

```lua
t.test("buildState: masterMode passes through from telemetry", function()
  local App = require("ui.basalt.app")
  local state = App.buildState({ latest = function() return { flightMode = "MAN", masterMode = "DCPL" } end }, {})
  t.eq(state.masterMode, "DCPL", "masterMode carried to cadence state")
end)
```

(Match the real `buildState` call signature used elsewhere in that test file; the key assertion is `state.masterMode == "DCPL"`.)

- [ ] **Step 2: Run to verify it fails** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "masterMode passes through|FAIL"`. Expected: FAIL — `masterMode carried...: expected DCPL got nil`.

- [ ] **Step 3: Write minimal implementation** — In `ui/basalt/app.lua`, in the `buildState` return table (beside `flightMode = latest.flightMode,` around line 746), add:

```lua
    masterMode   = latest.masterMode,
```

In `ui/basalt/cadence.lua`, add `tostring(state.masterMode)` to the FCS/flight signature list (beside `tostring(state.flightMode)`).

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "masterMode passes through|passed"`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/app.lua ui/basalt/cadence.lua tests/test_params.lua
git commit -m "feat(ui): buildState/cadence carry masterMode"
```

---

### Task 12: Basalt standalone FCS page — master-switch row

**Files:**
- Modify: `ui/basalt/pages/fcs.lua`
- Test: `tests/test_page_fcs.lua`

**Interfaces:**
- Consumes: `FcsPanel.MASTERS`, `FcsPanel.MASTER_LABEL`, `FcsPanel.masterActive`, `FcsPanel.action`.
- Produces: a second selector row of two switches (CPL/DCPL) below the flight-mode row, dispatching through the same `M._onButton` seam; `apply(state)` lights the reported `state.masterMode`. The TRIM button and status rows shift down one row to make room.

- [ ] **Step 1: Write the failing test** — in `tests/test_page_fcs.lua`, add a case asserting the page builds master switches and lights them from `masterMode` (match the file's existing element-introspection pattern; the page returns an `elements` table):

```lua
t.test("page/fcs: master switches present and driven by masterMode", function()
  -- build the page with the file's existing harness (fake basalt/frame/runtime), then:
  -- apply({ flightMode = "MAN", masterMode = "DCPL", trimDir = -1 })
  -- assert the DCPL master switch is "on" and CPL is "off".
  -- (Use the same assertion helpers the neighboring page tests use.)
end)
```

Fill the case body using the harness already present in `tests/test_page_fcs.lua` (it constructs the page and calls `apply`). Assert: after `apply` with `masterMode = "DCPL"`, the DCPL switch state is on and CPL off; with `masterMode = "CPL"` the reverse.

- [ ] **Step 2: Run to verify it fails** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "master switches present|FAIL tests.test_page_fcs"`. Expected: FAIL (no master switches yet).

- [ ] **Step 3: Write minimal implementation** — In `ui/basalt/pages/fcs.lua`:

1. Add a master row after the flight-mode selector loop (after the `modeSwitches` build, ~line 128). Build two switches from `FcsPanel.MASTERS` splitting `iw`, at `y = phTop + 1`:

```lua
  local masterTop = phTop + 1
  local mCount = #FcsPanel.MASTERS
  local mW = math.max(1, math.floor(iw / mCount))
  local masterSwitches = {}
  local mx = x
  for i, id in ipairs(FcsPanel.MASTERS) do
    local width = (i == mCount) and math.max(1, iw - (mW * (mCount - 1))) or mW
    masterSwitches[id] = Switch.make(frame, { x = mx, y = masterTop, width = width, height = 1,
      text = FcsPanel.MASTER_LABEL[id] or id })
    mx = mx + width
  end
```

2. Shift the TRIM button and `statusTop` down one row: change `trimBtn` y from `phTop + 1` to `phTop + 2`, and `statusTop = phTop + 3` to `phTop + 4` (keep the `if statusTop + statusWant - 1 > h` clamp, bumping its floor to `phTop + 3`).

3. Wire master switch clicks (mirroring the flight-mode loop):

```lua
  for _, id in ipairs(FcsPanel.MASTERS) do
    masterSwitches[id].button:onClick(function()
      M._onButton(runtime, id, os.epoch("utc"))
    end)
  end
```

4. In `apply(state)`, after the flight `modeSwitches` loop, add:

```lua
    for _, id in ipairs(FcsPanel.MASTERS) do
      masterSwitches[id].set(FcsPanel.masterActive(state, id) and "on" or "off")
    end
```

5. Add `masterSwitches` to the returned `elements` table if the file exposes elements for tests.

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "master switches present|passed"`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/pages/fcs.lua tests/test_page_fcs.lua
git commit -m "feat(ui): FCS page master-mode selector row (CPL/DCPL)"
```

---

### Task 13: Basalt merged FCS region — master chips

**Files:**
- Modify: `ui/basalt/regions/fcs.lua`
- Test: `tests/test_region_fcs_modes.lua`

**Interfaces:**
- Consumes: `FcsPanel.MASTERS`, `FcsPanel.masterActive`, `FcsPanel.action`.
- Produces: two master chips (CPL/DCPL) in the merged flight region, dispatching via the same `_onButton` seam, coloured green when `state.masterMode` matches. Flight-mode chips stay as-is (now five).

- [ ] **Step 1: Write the failing test** — in `tests/test_region_fcs_modes.lua`, add a case (matching the file's existing chip harness) asserting: the region builds CPL and DCPL chips, and after `apply({ masterMode = "DCPL" })` the DCPL chip is green (`colors.green`) and CPL red. Adjust any existing case that iterated 7 flight chips to iterate 5.

- [ ] **Step 2: Run to verify it fails** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "FAIL tests.test_region_fcs_modes"`. Expected: FAIL (no master chips / stale 7-count).

- [ ] **Step 3: Write minimal implementation** — In `ui/basalt/regions/fcs.lua`:

1. Where the flight-mode chips are built from `FcsPanel.MODES` (the `modeCtrls` grid, ~lines 117-143), add a small row/pair of master chips built from `FcsPanel.MASTERS` into a `masterCtrls` table, placed on a free row of the region (pick the next `y` below the flight chips; keep within the region height — mirror the existing `chipButton(frame, col, y, w, label)` calls).
2. Wire their taps through the same seam the flight chips use (`FcsPanel.action(id)` → `_onButton`).
3. In `apply(state)`, after the flight `modeCtrls` colouring loop (~line 162), add:

```lua
    for _, id in ipairs(FcsPanel.MASTERS) do
      if masterCtrls[id] then
        masterCtrls[id].setChip(FcsPanel.masterActive(state, id) and colors.green or colors.red)
      end
    end
```

4. Keep the existing `trimCtrl` line; it already reads `FcsPanel.trimActive`, which now keys off `masterMode`.

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "FAIL tests.test_region_fcs_modes|passed"`. Expected: no region_fcs_modes failure.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/regions/fcs.lua tests/test_region_fcs_modes.lua
git commit -m "feat(ui): merged FCS region master-mode chips (CPL/DCPL)"
```

---

### Task 14: Tuning config editor — retire CPL/DCPL rows, share trim/ramp rows

**Files:**
- Modify: `ui/basalt/bitconfig/tuning.lua`
- Test: `tests/test_bitconfig_tuning.lua`

**Interfaces:**
- Produces: `MODE_EXTRA_ROWS` no longer has `CPL`/`DCPL` keys. The shared base FEEL rows gain `feel.climbRampTime`, `feel.climbBoost`, `feel.trimGain` (so every flight mode can tune them, since trim/ramp now apply everywhere). `pathFor("PRECISION", "feel.trimGain")` resolves to the top-level `feel.trimGain` path.

- [ ] **Step 1: Write the failing test** — in `tests/test_bitconfig_tuning.lua`, add:

```lua
t.test("tuning editor: no CPL/DCPL extra rows; trim/ramp are shared base FEEL rows", function()
  local T = require("ui.basalt.bitconfig.tuning")
  -- CPL/DCPL are no longer tunable flight modes
  local specCPL = T.specFor and T.specFor("CPL", "feel.trimGain")
  t.eq(specCPL, nil, "no CPL-scoped trimGain row")
  -- trimGain/climbBoost/climbRampTime now resolve for a base flight mode (e.g. MAN)
  t.truthy(T.specFor("MAN", "feel.trimGain"), "trimGain tunable on a flight mode")
  t.truthy(T.specFor("MAN", "feel.climbBoost"), "climbBoost tunable on a flight mode")
  t.truthy(T.specFor("MAN", "feel.climbRampTime"), "climbRampTime tunable on a flight mode")
end)
```

Note: `specFor(mode, rowId)` is a **local** function in the file (not yet exported). Export it for the test by adding `M.specFor = specFor` near the file's other `M.*` exports (after its definition, ~line 242). If `tests/test_bitconfig_tuning.lua` already reaches rows through another public accessor, use that instead and drop the `M.specFor` export.

- [ ] **Step 2: Run to verify it fails** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "shared base FEEL rows|FAIL tests.test_bitconfig_tuning"`. Expected: FAIL — `no CPL-scoped trimGain row: got table` (CPL rows still present).

- [ ] **Step 3: Write minimal implementation** — In `ui/basalt/bitconfig/tuning.lua`:

1. Delete the `CPL = { ... }` and `DCPL = { ... }` entries from `MODE_EXTRA_ROWS` (leaving `MAN` and `CRUISE`).
2. Add three rows to the shared base FEEL rows (the `ROW_SPEC` list that carries the base `FEEL` group — find the existing `feel.*` base rows and append):

```lua
  { id = "feel.climbRampTime", label = "CLIMB RAMP TIME", group = "FEEL", step = 0.1,  min = 0.1, max = 5.0 },
  { id = "feel.climbBoost",    label = "CLIMB BOOST",     group = "FEEL", step = 0.1,  min = 0.5, max = 5.0 },
  { id = "feel.trimGain",      label = "TRIM GAIN",       group = "FEEL", step = 0.01, min = 0,   max = 1.0 },
```

3. Update the file's header comment and any FEEL-row-count/fit assertion the test file enforces (the comment references a fit-regression test — re-count rows and adjust the expected count so the region-budget assertion in `tests/test_bitconfig_tuning.lua` still holds; if the added rows overflow the ~12-row budget for a mode's FEEL screen, split the FEEL group across screens the way the file already paginates, or reduce to the rows that fit and log the rest — do NOT silently drop a row).

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/run_headless.sh 2>&1 | grep -E "shared base FEEL rows|passed"`. Expected: pass and no fit-regression failure.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/tuning.lua tests/test_bitconfig_tuning.lua
git commit -m "feat(ui): tuning editor retires CPL/DCPL rows; trim/ramp become shared FEEL rows"
```

---

### Task 15: Regenerate build artifacts + full-suite verification

**Files:**
- Modify (generated): `dist/**`, `manifest.lua`, `manifest-dev.lua`, `easyhover2_suite.lua`, `easyhover2_suitex.lua` (whatever the build emits)

**Interfaces:** none (build + verify only).

- [ ] **Step 1: Confirm the source suite is green** — Run: `bash tests/run_headless.sh 2>&1 | tail -3`. Expected: `NNNN passed, 0 failed`. If not, fix the failing suite before building.

- [ ] **Step 2: Regenerate dist + manifests** — Run the project build (defined in `package.json` as the `build` script):

```bash
npm run build   # == node tools/build.mjs
```

Expected: `dist/` refreshed, manifests rewritten, no error. (Check `git status` shows only generated files changed.)

- [ ] **Step 3: Run the dist suite + manifest sync check** — Run:

```bash
bash tests/run_headless_dist.sh 2>&1 | tail -3
bash tools/check_github_sync.sh 2>&1 | tail -3 || true
```

Expected: dist suite `NNNN passed, 0 failed`; the run also prints `== manifest sync check == IN SYNC` (as the source suite does). If the dist copies of the deleted `coupled.lua`/`decoupled.lua` or coupled tests still linger under `dist/`/`tests/.craftos`, the build should have removed them; if not, remove stale generated files and rebuild.

- [ ] **Step 4: Run the e2e suite (if present)** — Run: `bash tests/run_suite_e2e.sh 2>&1 | tail -5`. Expected: green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "build: dist + manifests for flight/master mode split"
```

---

## Self-Review

**Spec coverage:**
- §1/§2 orthogonal selectors → Tasks 2, 3, 8, 10 (registry split, master registry, flight state, UI logic). ✓
- §3 deletions (coupled schemes/keymap/pilot blocks) → Tasks 3, 5, 6. ✓
- §4 unified hold/relax rule → Task 6 (`test_pilot_drift`). ✓
- §5 trim feedforward from surge demand, all modes, lift-differential-only → Task 7 (`test_loop_trim`) + Tasks 1/8 (gain source + threading). ✓
- §6 DRN bugfix (scheme + caps) → Tasks 4 (scheme) + 1 (caps). ✓
- §7 rampable climb always-on → Task 6 (`ramped climb` case). ✓
- §8 UI: all seven buttons, two independent groups, telemetry-driven → Tasks 10 (logic), 11 (state), 12 (page), 13 (region). `masterMode` telemetry + `masterMode` command → Tasks 8, 11. ✓
- §9 tests → each task carries its own; tuning editor consumer → Task 14. ✓
- §10 out-of-scope (effectiveness/AP/channels) → not implemented; noted. ✓

**Placeholder scan:** Tasks 12/13 leave the exact chip-placement/harness assertions to the file's existing patterns rather than inventing fake APIs — those two UI files use bespoke chip/switch harnesses this plan cannot fully reproduce blind; the step text names the exact functions to call (`Switch.make`, `chipButton`, `FcsPanel.masterActive`, `_onButton`) and the exact assertion (reported `masterMode` lights the matching control). This is intentional, not a TBD. All code-bearing steps contain real code.

**Type consistency:** `driftArrest` (bool) — produced by `master.byId[id].driftArrest`, consumed by `pilot:setMaster`. `trimDir`/`trimGain` — set by `loop:setTrim(dir, gain)`, sourced from `feel.trimGain` + `flight.trimDir`. `masterMode` (string) — set by `{k="masterMode",id=}`, stored on `Flight.masterMode`, emitted on `snapshot.masterMode`, carried by `buildState.masterMode`, read by `FcsPanel.masterActive(ctx.masterMode)` / `trimActive`. Names consistent across tasks. ✓

## Execution Handoff

(Provided after saving.)
