# fcslog Instrumentation Schema Expansion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand the `fcslog` flight-instrumentation CSV with high-value diagnostic columns (per-axis setpoints, errors, the P/I/D split, saturation flags, trim feedforward, context) — reconstructed entirely from already-stored control state at log time — so a test flight's oscillation/drift behavior is *attributable*, not just visible.

**Architecture:** ZERO new work in the control path. The controllers already persist `kp/ki/kd`, the integral `self.i`, and the filtered derivative `self.dFilt`; the loop already persists `self._sat`, `self.trimDir/trimGain`; `pilot.sp` already holds every setpoint. We add READ-ONLY `:terms()`/`:diag()` methods that reconstruct P/I/D/error from that stored state, and we call them ONLY from inside the existing `if not LOGGING then return end` gate in `tools/flight.lua`'s `logCycle`. Control-loop return values are unchanged. CSV formatting stays deferred to dump-time (P-press/exit), off the hot path.

**Tech Stack:** Lua 5.1 / CC:Tweaked, CraftOS-PC headless test harness, `tests/framework.lua`.

## Global Constraints

- **NO-OP WHEN `fcslog` IS OFF — the top requirement.** Production launches (`fcs`/`flight`) do NOT set `_G.EH2_FLIGHTLOG`, so `LOGGING` is false and every logging branch is a single boolean check. The new `:terms()`/`:diag()` methods on the controllers/scheme/loop MUST be *pure reads* (no mutation of controller/loop state) and MUST be called ONLY from inside `logCycle`/`logStart`/`logWriteFile`, all already gated by `if not LOGGING then return end`. Defining a method that is never called adds zero runtime cost. **No task may add any per-cycle work to the control path (`Loop:cycle`, `Scheme:update`, `Pid/Heading/Translate:update`, `Flight:step`) — those functions' behavior and return values stay byte-for-byte identical.** A reviewer must be able to confirm the control path is untouched except for pure additive methods.
- **Do not starve the FCS when logging IS on.** Per-cycle logging work stays limited to: reading already-stored scalars, one `loop:diag()` pure read, building one flat sample table, one summary min/max update, one ring-buffer push. NO `string.format` / file IO per cycle (that stays in `logWriteFile`, called only on P-press/exit). This preserves the fix that stopped logging-on flights running ~15Hz jittery.
- **ASCII only** in every string/comment (`--`, no unicode).
- **TDD** — RED (write failing test, run, confirm expected failure) → GREEN (minimal impl, run, confirm) → commit. Framework `tests/framework.lua` (`t.test/eq/near/truthy`).
- **Manifest gate:** `bash tests/run_headless.sh` runs `tools/run_gen.sh --check` first and refuses if `manifest.lua`/`manifest-dev.lua` are stale. After editing any source file in the require-closure, run `bash tools/run_gen.sh`, THEN the suite, and `git add manifest.lua manifest-dev.lua`. `manifest*.lua` is GENERATED. Register any new test file in `tests/run_headless.sh`'s `suites` array (and `tests/run_headless_dist.sh`'s for the dist run).
- **Suites:** `bash tests/run_headless.sh` (source, expect `.../0 failed`), `bash tests/run_headless_dist.sh` (dist, 0 failed), `bash tests/run_suite_e2e.sh` (green). Never hand-edit `dist/**`.
- **`hover_test.lua` co-consumes the instrument.** `instrument.formatRow`'s `num()` must remain nil-safe so `hover_test.lua` (which does not supply the new fields) emits blanks in the new columns without erroring. Do NOT break `tools/hover_test.lua`.

## THE COLUMN CONTRACT (canonical — every task must match this exactly)

`instrument.header()` emits columns in THIS order: the 23 existing scalar columns, then the new scalar columns below, then the per-thruster duty columns (unchanged, last). Column names are the CSV header strings.

**Existing (unchanged, 23):** `t,dt_ms,hz,phase,mode,sp_alt,alt,vSpeed,pitch,roll,heading,yawRate,swayVel,surgeVel,swayPos,surgePos,onGround,heave,dPitch,dRoll,dYaw,dSway,dSurge`

**New columns (appended, in this order):**
1. Setpoints (5) — from `pilot.sp`: `sp_pitch,sp_roll,sp_hdg,sp_sway,sp_surge`
2. Errors (6) — DERIVED at format time (NOT stored in the sample), each = setpoint - measured: `err_alt,err_pitch,err_roll,err_hdg,err_sway,err_surge`
   - `err_alt = sp_alt - alt`, `err_pitch = sp_pitch - pitch`, `err_roll = sp_roll - roll`, `err_hdg = sp_hdg - heading`, `err_sway = sp_sway - swayPos`, `err_surge = sp_surge - surgePos`. (Plain subtraction; heading wrap is a nicety, not required — log raw difference.)
3. PID split (18) — STORED, from `loop:diag().terms` (see below): `P_alt,I_alt,D_alt,P_pitch,I_pitch,D_pitch,P_roll,I_roll,D_roll,P_yaw,I_yaw,D_yaw,P_sway,I_sway,D_sway,P_surge,I_surge,D_surge`
4. Saturation (7) — STORED, from `loop:diag().sat` (per-axis bool) + `.heaveBanded`: `sat_heave,sat_pitch,sat_roll,sat_yaw,sat_sway,sat_surge,heaveBanded` (emit "1"/"0")
5. Trim feedforward (1) — STORED: `ff_pitch` = `trimDir * trimGain * dSurge` (the exact bias `Loop:cycle` adds to `demands.pitch`)
6. Context (2) — STORED: `master` (the master mode string, e.g. "CPL"/"DCPL", or "" if unavailable), `noFuel` ("1"/"0")

Total new = 5 + 6(derived) + 18 + 7 + 1 + 2 = 39 columns. `num(nil)` renders blank/0 for any field a caller omits (hover_test path).

**Per-axis terms table shape** (`Pid:terms(...)` etc. return, and `Scheme:terms`/`Loop:diag().terms` assemble): each axis = `{ err=<n>, P=<n>, I=<n>, D=<n> }`. Assembled table keyed by axis: `{ alt=?, pitch=?, roll=?, yaw=?, sway=?, surge=? }`.

**RAM note:** the ring buffer (`MAX_ROWS=3000`, ~3 min @16Hz) retains raw sample tables. Storing ~31 extra scalar fields/sample (`err_*` are NOT stored — derived at format) grows RAM modestly. Keep `MAX_ROWS=3000` (time coverage matters most); it is already an easy knob to lower if in-world GC pressure appears.

---

## File Structure

- `fcs/control/pid.lua` — add pure `Pid:terms(sp, meas)` (Task 1)
- `fcs/control/heading.lua` — add pure `Heading:terms(sp, meas, yawRate)` (Task 1)
- `fcs/control/translate.lua` — add pure `Translate:terms(sp, pos, vel)` (Task 1)
- `fcs/schemes/level_flight.lua` — add pure `Scheme:terms(sp, m)` assembler (Task 2)
- `fcs/runtime/loop.lua` — add pure `Loop:diag(sp, m)` read (Task 3)
- `fcs/bringup/instrument.lua` — expand header/formatRow/Summary (Task 4)
- `tools/flight.lua` — expand `logCycle`'s sample from the new sources, still gated (Task 5)
- Tests: `tests/test_control_terms.lua` (new, Task 1), extend `tests/test_scheme_heave.lua` or a new `tests/test_scheme_terms.lua` (Task 2), extend `tests/test_loop*` or new `tests/test_loop_diag.lua` (Task 3), `tests/test_instrument.lua` (Task 4).

---

### Task 1: Controller `:terms()` pure read methods

Add a read-only `:terms()` to each of the three controllers that reconstructs `{err, P, I, D}` from stored state, matching what its `:update()` last returned. NO mutation, NO change to `:update()`.

**Files:**
- Modify: `fcs/control/pid.lua`, `fcs/control/heading.lua`, `fcs/control/translate.lua`
- Test: `tests/test_control_terms.lua` (new; register in `tests/run_headless.sh` suites)

**Interfaces (Produces):**
- `Pid:terms(sp, meas) -> { err=sp-meas, P=self.kp*(sp-meas), I=self.i, D=(self.kd~=0) and (-self.kd*self.dFilt) or 0 }`
- `Heading:terms(sp, meas, yawRate) -> { err=<wrapped or raw sp-meas per how update computes err>, P=self.kp*err, I=self.i, D=-self.kd*(yawRate or 0) }` — read `heading.lua`'s `:update` to use the SAME err definition (it uses `angle.wrap` on the heading error; reuse that).
- `Translate:terms(sp, pos, vel) -> { err=sp-pos, P=self.kp*(sp-pos), I=self.i, D=-self.kd*(vel or 0) }`

- [ ] **Step 1: Read the three `:update` bodies** (`pid.lua:13-34`, `heading.lua`, `translate.lua`) so `:terms` uses the identical P/I/D expressions and err definition (esp. heading's `angle.wrap`).

- [ ] **Step 2: Write failing tests.** Create `tests/test_control_terms.lua`. For each controller: construct with known `kp/ki/kd`, drive `:update(...)` one or more cycles to populate `i`/`dFilt`, then assert `:terms(...)` returns P/I/D whose SUM equals the last `:update` return (within `t.near`), and that `terms.I == <the controller's stored i>`, `terms.err == <expected>`. Also assert `:terms` does NOT mutate state (call `:update`, snapshot `i`/`dFilt`, call `:terms` twice, assert `i`/`dFilt` unchanged and a subsequent `:update` returns what it would have without the `:terms` calls).

```lua
-- tests/test_control_terms.lua (shape)
local t = require("tests.framework")
local Pid = require("fcs.control.pid")
t.test("Pid:terms P+I+D sums to update() and does not mutate", function()
  local p = Pid.new({ kp = 2, ki = 0.5, kd = 0.1, tauD = 0 })
  local out = p:update(1.0, 0.0, 0.1, false)   -- sp=1, meas=0, dt=0.1
  local i0, d0 = p.i, p.dFilt
  local tm = p:terms(1.0, 0.0)
  t.near(tm.P + tm.I + tm.D, out, 1e-6, "P+I+D == update() return")
  t.near(tm.err, 1.0, 1e-9)
  t.eq(p.i, i0, "terms must not mutate i"); t.eq(p.dFilt, d0, "terms must not mutate dFilt")
end)
-- ...analogous tests for Heading (with yawRate) and Translate (with vel)...
```

- [ ] **Step 3: Run to confirm RED.** `bash tests/run_headless.sh 2>&1 | grep -iE "terms|failed" | tail` (add the suite entry first). Expect "attempt to call ... terms (a nil value)".

- [ ] **Step 4: Implement the three `:terms` methods** as read-only reconstructions matching each `:update`. Add nothing to `:update`.

- [ ] **Step 5: Regen + run.** `bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | tail -5` → `0 failed`.

- [ ] **Step 6: Commit.**

```bash
git add fcs/control/pid.lua fcs/control/heading.lua fcs/control/translate.lua tests/test_control_terms.lua tests/run_headless.sh manifest.lua manifest-dev.lua
git commit -m "feat(fcs): read-only :terms() P/I/D reconstruction on pid/heading/translate (log-time only)"
```

---

### Task 2: `level_flight.Scheme:terms(sp, m)` assembler

Add a pure `:terms(sp, m)` to the base Level scheme that assembles the 6 per-axis term tables by calling each controller's `:terms`. Reachable for the wrapper schemes (manual/drone/cruise) via their `.inner` Level — so NO wrapper files change.

**Files:**
- Modify: `fcs/schemes/level_flight.lua`
- Test: `tests/test_scheme_terms.lua` (new; register in suites) — or extend `tests/test_scheme_heave.lua` if that is the level_flight suite (check its `require`).

**Interfaces (Produces):**
- `Scheme:terms(sp, m) -> { alt=altPid:terms(sp.altitude or 0, m.altitude or 0), pitch=pitchPid:terms(sp.pitch or 0, m.pitch or 0), roll=rollPid:terms(sp.roll or 0, m.roll or 0), yaw=headingPid:terms(sp.heading or 0, m.heading or 0, m.yawRate or 0), sway=swayTc:terms(sp.swayPos or 0, m.swayPos or 0, m.swayVel or 0), surge=surgeTc:terms(sp.surgePos or 0, m.surgePos or 0, m.surgeVel or 0) }` — argument order per each controller's `:update`/`:terms` signature from Task 1. Pure (no mutation, no `:update` call).

**Consumes:** Task 1's `:terms` methods.

- [ ] **Step 1: Write failing test.** Build a `Level.new({...})` with known gains, run one `:update(sp, m, dt, false, {})`, then `:terms(sp, m)`; assert all 6 axes present, each has `err/P/I/D`, and e.g. `terms.pitch.P + .I + .D` is finite and `terms.alt.I == altPid.i`. Also assert reachability via a wrapper: `local Manual = require("fcs.schemes.manual"); local w = Manual.new({...}); (w.inner):terms(sp,m)` returns the 6 axes (documents the `.inner` access path Task 3 uses).

- [ ] **Step 2: Run RED** → `terms (a nil value)`.

- [ ] **Step 3: Implement `Scheme:terms`** in `level_flight.lua` (pure).

- [ ] **Step 4: Regen + run** → `0 failed`.

- [ ] **Step 5: Commit.**

```bash
git add fcs/schemes/level_flight.lua tests/test_scheme_terms.lua tests/run_headless.sh manifest.lua manifest-dev.lua
git commit -m "feat(fcs): level_flight Scheme:terms(sp,m) per-axis PID split assembler (pure)"
```

---

### Task 3: `Loop:diag(sp, m)` pure read

Add a pure `Loop:diag(sp, m)` that returns the log-site diagnostic bundle from already-stored loop/scheme state. Called ONLY from the gated `logCycle`. `Loop:cycle` is UNCHANGED.

**Files:**
- Modify: `fcs/runtime/loop.lua`
- Test: `tests/test_loop_diag.lua` (new; register in suites)

**Interfaces (Produces):**
- `Loop:diag(sp, m) -> { terms = level and level:terms(sp, m) or nil, sat = self._sat or {}, heaveBanded = (level and level._heaveSat) or false, trimDir = self.trimDir or 0, trimGain = self.trimGain or 0 }` where `local level = (self.scheme and self.scheme.inner) or self.scheme` (Level directly for PRECISION/LDG; via `.inner` for manual/drone/cruise). Pure: reads only; no mutation; does not call `:update`/`:cycle`.

**Consumes:** Task 2's `Scheme:terms`; `self._sat` (set by `Loop:cycle`), `self.trimDir/trimGain` (set by `Loop:setTrim`).

- [ ] **Step 1: Write failing test.** Build a Loop with a Level scheme + mixer stub, `:arm(true)`, `:setTrim(1, 0.2)`, run one `:cycle(dt, m)`, then `diag(sp, m)`: assert `terms.pitch` present, `sat` is a table, `trimDir==1`, `trimGain==0.2`. Assert `diag` does not change `self._sat` or scheme state (snapshot before/after).

- [ ] **Step 2: Run RED.**

- [ ] **Step 3: Implement `Loop:diag`** (pure; the `(self.scheme.inner or self.scheme)` resolution).

- [ ] **Step 4: Regen + run** → `0 failed`.

- [ ] **Step 5: Commit.**

```bash
git add fcs/runtime/loop.lua tests/test_loop_diag.lua tests/run_headless.sh manifest.lua manifest-dev.lua
git commit -m "feat(fcs): Loop:diag(sp,m) log-site read of PID terms + saturation + trim (pure)"
```

---

### Task 4: Instrument schema expansion

Expand `fcs/bringup/instrument.lua`'s header/formatRow/Summary per THE COLUMN CONTRACT. New scalar columns appended before the duty columns; `err_*` DERIVED in `formatRow` (not stored). Keep `num()` nil-safe. `capture()` unchanged (still snapshots only `duties`). Extend the Summary with per-axis peak `|err|` and peak `|D|`.

**Files:**
- Modify: `fcs/bringup/instrument.lua`
- Test: `tests/test_instrument.lua`

**Interfaces (Produces / consumes):** `formatRow(s)` reads new `s` fields: `s.sp_pitch/sp_roll/sp_hdg/sp_sway/sp_surge`, `s.terms` (`{alt/pitch/roll/yaw/sway/surge = {err,P,I,D}}`), `s.sat` (`{heave/pitch/roll/yaw/sway/surge=bool}`), `s.heaveBanded`, `s.ff_pitch`, `s.master`, `s.noFuel`. `err_*` computed from `s.sp_* - s.<measured>` (measured already in `s`: alt/pitch/roll/heading/swayPos/surgePos). Any missing field → `num(nil)` blank. This is the shape Task 5 builds.

- [ ] **Step 1: Write failing tests** in `tests/test_instrument.lua`:
  - `header()` contains the new column names in the contract order (assert a few key ones and the total count).
  - `formatRow(sample)` with a fully-populated sample (including `terms`, `sat`, `sp_*`, `ff_pitch`, `master`, `noFuel`) emits the P/I/D values, the `sat` as "1"/"0", `heaveBanded`, `ff_pitch`, and the DERIVED `err_pitch == sp_pitch - pitch`, etc., in the right positions (split the row on "," and index by the header's column index).
  - `formatRow(minimalSample)` (no new fields — the hover_test path) does NOT error and emits blanks for the new columns (nil-safe).
  - `Summary` tracks new peaks (feed a couple of samples, assert `finalize()`/`formatSummary` include the per-axis peak |err| and peak |D|).

- [ ] **Step 2: Run RED.**

- [ ] **Step 3: Implement.** Extend `SCALAR_COLS`/`header()` (append the new columns per contract; the duty columns still come last), extend `formatRow` (pull the new fields, derive `err_*`, format `sat`/`heaveBanded`/`noFuel` as "1"/"0"), keep `capture()` snapshotting only `duties`, extend `Summary.new/add/finalize/formatSummary` with per-axis peak |err| and peak |D| (read `s.terms`). ASCII only. Confirm `num(nil)` yields a safe blank/0.

- [ ] **Step 4: Regen + run** → `0 failed`.

- [ ] **Step 5: Commit.**

```bash
git add fcs/bringup/instrument.lua tests/test_instrument.lua manifest.lua manifest-dev.lua
git commit -m "feat(fcs): expand flight-instrument CSV — setpoints, err, PID split, saturation, trim, context"
```

---

### Task 5: `tools/flight.lua` logCycle wiring (still gated)

Build the expanded sample in `logCycle` from the new sources, entirely inside the existing `if not LOGGING then return end` gate. Call `flight.loop:diag(pilot.sp, m)` ONCE per logged cycle. No change to the non-logging path.

**Files:**
- Modify: `tools/flight.lua`

**Interfaces (Consumes):** `pilot.sp` (setpoints), `m` (measured), `flight.loop:diag(pilot.sp, m)` (Task 3 → `{terms, sat, heaveBanded, trimDir, trimGain}`), `flight.lastDiag` (`.demands.surge` for `ff_pitch` cross-check — but compute `ff_pitch = diag.trimDir * diag.trimGain * (dem.surge or 0)`), the master mode + noFuel from the runtime.

- [ ] **Step 1: Locate the sources in `tools/flight.lua`.** Confirm `flight.loop` is reachable and `pilot` is in scope at `logCycle` (it already reads `pilot.sp.altitude`). Find where the master mode and `noFuel` are readable (e.g. off `flight` or the latest snapshot the loop already built — reuse what `logCycle` already has; if `master`/`noFuel` are not trivially reachable, set them to `nil`/false and note it — the columns degrade to blank, per contract). Do NOT add new peripheral reads.

- [ ] **Step 2: Extend the `sample` table** in `logCycle` with: `sp_pitch = pilot.sp.pitch or 0, sp_roll = pilot.sp.roll or 0, sp_hdg = pilot.sp.heading or 0, sp_sway = pilot.sp.swayPos or 0, sp_surge = pilot.sp.surgePos or 0`; `local d = flight.loop:diag(pilot.sp, m)`; `terms = d.terms, sat = d.sat, heaveBanded = d.heaveBanded, ff_pitch = (d.trimDir or 0) * (d.trimGain or 0) * ((dem.surge) or 0)`; `master = <master mode string or nil>, noFuel = <bool or false>`. Keep this ENTIRELY after the `if not LOGGING then return end` guard.

- [ ] **Step 3: NO-OP verification.** Re-read the final `logCycle`/`logStart`/`logWriteFile` to confirm: (a) every new read (`flight.loop:diag`, `pilot.sp.*`) is below the `if not LOGGING then return end` line, so production (`_G.EH2_FLIGHTLOG` unset) never calls `:diag` or touches the new sources; (b) `Loop:cycle`/`Scheme:update`/controllers are unchanged. State this explicitly in the report. (tools/flight.lua is an entry script — validate by reading + the full suite, and by grepping that `:diag(`/`pilot.sp.` appear only inside the gated logging functions.)

- [ ] **Step 4: Regen + run the suite** (this file is in the closure): `bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | tail -5` → `0 failed`. If `tools/flight.lua` has no direct unit test, the gate is the suite staying green + the read-audit in Step 3.

- [ ] **Step 5: Commit.**

```bash
git add tools/flight.lua manifest.lua manifest-dev.lua
git commit -m "feat(fcs): fcslog logCycle records the expanded schema (gated; NO-OP when fcslog off)"
```

---

### Task 6: Build + dist + e2e gate

**Files:** possibly `tests/run_headless_dist.sh` (register any new test modules: `test_control_terms`, `test_scheme_terms`, `test_loop_diag`); generated `dist/**`, manifests.

- [ ] **Step 1: Build + regen.** `npm run build && bash tools/run_gen.sh`.
- [ ] **Step 2: Register new tests in the dist runner.** Add `"tests.test_control_terms"`, `"tests.test_scheme_terms"`, `"tests.test_loop_diag"` (whichever were created) to `tests/run_headless_dist.sh`'s `suites` array.
- [ ] **Step 3: Suites.** `bash tests/run_headless.sh 2>&1 | tail -3` (0 failed), `bash tests/run_headless_dist.sh 2>&1 | tail -3` (0 failed), `bash tests/run_suite_e2e.sh 2>&1 | tail -5` (green).
- [ ] **Step 4: Commit.**

```bash
git add -A
git commit -m "build: regenerate dist + manifests; register new instrument tests in the dist runner"
```

---

## Self-Review notes
- **Spec coverage:** Tasks 1-3 build the pure read path (controllers → scheme → loop); Task 4 the CSV schema; Task 5 the gated wiring; Task 6 ships. The COLUMN CONTRACT is the shared source of truth across Tasks 4 & 5.
- **NO-OP invariant:** the only control-path files touched (pid/heading/translate/level_flight/loop) receive ADDITIVE pure methods only; their `:update`/`:cycle` bodies are unchanged (a reviewer confirms this per task). All calls to the new methods live behind `logCycle`'s existing gate.
- **hover_test compatibility:** `num()` stays nil-safe; new columns blank there.
- **Type consistency:** the per-axis terms table `{err,P,I,D}` and the `{alt,pitch,roll,yaw,sway,surge}` keying are identical across Tasks 1→2→3→4→5.
