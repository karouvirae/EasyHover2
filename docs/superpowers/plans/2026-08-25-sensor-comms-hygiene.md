# Sensor Comms Hygiene — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the FCS the sole reader of craft sensors and single broadcast source; UI/NAV consume the snapshot instead of polling, deleting all duplicate/background sensor reads.

**Architecture:** The FCS already broadcasts a telemetry snapshot on ch 101 (`Flight:snapshot` → `tools/flight.lua` → UI `routeModem`/`runtime.rx`). We (1) extend that snapshot with the fields the UI's attitude/heading display needs, (2) re-route the UI + NAV to read them from the snapshot, and (3) delete the UI's local attitude poll and NAV's navtable read. FCS reads/control loop are unchanged.

**Tech Stack:** Lua 5.1 / CC:Tweaked, Basalt 2.0 (full build), headless CraftOS-PC test harness.

## Global Constraints

- Language: Lua 5.1 (CC:Tweaked). No new deps.
- Tests: headless CraftOS. Full suite: `bash tests/run_headless.sh`. Fast single/few modules: `bash "<scratchpad>/run_some.sh" tests.test_x tests.test_y` (mirrors run_headless without the manifest gate).
- TDD: write the failing test, watch it fail, minimal impl, watch it pass, commit. No real peripherals in tests — inject/mock (`wrap`, `readFn`, fake navtable/modem as existing tests do).
- Branch: `refactor/comms-hygiene` (already created off `main`). Never touch `main`. Revert target: `git reset --hard pre-comms-refactor`.
- Before the FINAL task's completion: regen manifest (`bash tools/run_gen.sh`) + build dist (`node tools/build.mjs`) so the tree is consistent; full suite must be green.
- Verify hardware/units claims in source, never assume (this repo's standing rule).

---

### Task 1: FCS snapshot — publish pitch / roll / surgeVel

**Files:**
- Modify: `fcs/runtime/flight.lua` — `Flight:snapshot(r, meas)` return table.
- Test: `tests/test_flight.lua`

**Interfaces:**
- Consumes: `meas` already carries `pitch, roll, surgeVel` (`fcs/io/backend.lua:sensors()` return, verified).
- Produces: snapshot table gains `pitch` (number|nil), `roll` (number|nil), `surgeVel` (number|nil).

- [ ] **Step 1: Write the failing test** in `tests/test_flight.lua` (add near the existing snapshot assertions):

```lua
t.test("snapshot publishes pitch/roll/surgeVel from meas (for UI attitude)", function()
  local f = newFlight()   -- use the file's existing Flight builder helper
  local meas = { pitch = 0.12, roll = -0.05, surgeVel = 3.4, onGround = false }
  local snap = f:snapshot(nil, meas)
  t.eq(snap.pitch, 0.12); t.eq(snap.roll, -0.05); t.eq(snap.surgeVel, 3.4)
end)
```
(If `test_flight.lua` has no `newFlight` helper, construct `Flight.new{...}` the same way the nearest existing test in the file does — reuse that file's setup verbatim.)

- [ ] **Step 2: Run to verify it fails** — `bash "<scratchpad>/run_some.sh" tests.test_flight` → FAIL (`snap.pitch` nil).
- [ ] **Step 3: Implement** — in `Flight:snapshot`, add to the returned table (alongside `vSpeed = m.vSpeed`):

```lua
    pitch = m.pitch, roll = m.roll, surgeVel = m.surgeVel,
```

- [ ] **Step 4: Run to verify it passes** — same command → PASS. Also run `tests.test_basalt_app` to confirm no snapshot consumers broke.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(fcs): publish pitch/roll/surgeVel in the telemetry snapshot"`

---

### Task 2: FCS snapshot — publish compassHeading (true 0–360° bearing)

The snapshot's existing `heading` is the FCS **control** value in **radians** (`fcs/io/backend.lua:50`, `signHeading * headingScale(deg→rad) * rawHeading`; `fcs/input/config.lua` `headingRate` is rad/s). Displays need a **compass bearing in degrees** = `wrap360(rawHeading * compassSign)` — the exact value NAV relays today (`nav/lib/heading.lua:absolute`). We publish it as a distinct `compassHeading` field.

**Files:**
- Modify: `fcs/io/backend.lua` — `sensors()` to also return `rawHeading`.
- Modify: `fcs/runtime/flight.lua` — `Flight:snapshot` to compute + publish `compassHeading`.
- Modify: `fcs/io/config.lua` (or wherever `bindings`/`sensors` config defaults live) — add a `compassSign` binding default (+1).
- Test: `tests/test_backend.lua` (rawHeading passthrough), `tests/test_flight.lua` (compassHeading math).

**Interfaces:**
- Produces: `meas.rawHeading` (number, raw `getRelativeAngle` degrees, 0 when silent). Snapshot gains `compassHeading` (number|nil, degrees in [0,360)).
- `compassSign`: `+1`/`-1` from `config.bindings.compassSign` (default +1), calibrated so a clockwise turn increases the bearing (same meaning as the old NAV `navtable.sign`).

- [ ] **Step 1: Failing test (backend)** — in `tests/test_backend.lua`, assert `sensors()` returns `rawHeading` equal to the mocked `getRelativeAngle` (reuse the file's existing backend+mock setup; the navTable mock returns a fixed angle, e.g. 47):

```lua
t.test("sensors() returns rawHeading = raw navtable getRelativeAngle", function()
  -- build backend with the file's existing mock shim; navTable.getRelativeAngle -> 47
  local s = backend:sensors()
  t.eq(s.rawHeading, 47)
end)
```

- [ ] **Step 2: Run → fail** — `run_some.sh tests.test_backend`.
- [ ] **Step 3: Implement (backend)** — in `fcs/io/backend.lua:sensors()`, after computing `rawHeading` (line ~49), add `rawHeading = rawHeading` to the returned table (line ~76-78).
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Failing test (snapshot compassHeading)** — in `tests/test_flight.lua`:

```lua
t.test("snapshot publishes compassHeading = wrap360(rawHeading * compassSign)", function()
  local f = newFlight({ bindings = { compassSign = -1 } })  -- pass config the file's builder accepts
  local snap = f:snapshot(nil, { rawHeading = 47 })
  t.eq(snap.compassHeading, 313)   -- wrap360(47 * -1) = 313
end)
t.test("snapshot compassHeading is nil when rawHeading is absent", function()
  local f = newFlight()
  t.eq(f:snapshot(nil, {}).compassHeading, nil)
end)
```

- [ ] **Step 6: Run → fail.**
- [ ] **Step 7: Implement (snapshot)** — `Flight` needs the compass sign. Thread it from config into `Flight.new` (store `self.compassSign = deps.compassSign or (deps.config and deps.config.bindings and deps.config.bindings.compassSign) or 1` — match how `Flight.new` already receives deps). In `Flight:snapshot`, compute:

```lua
    compassHeading = (type(m.rawHeading) == "number")
      and (function(d) d = d % 360; if d < 0 then d = d + 360 end; return d end)((m.rawHeading) * (self.compassSign or 1))
      or nil,
```
Prefer reusing `nav/lib/heading.lua`'s `wrap360` logic inline (as above) rather than adding a cross-package require from `fcs/`.

- [ ] **Step 8: Add the config default** — add `compassSign = 1` to the FCS bindings defaults in `fcs/io/config.lua` (next to `signHeading`). Add/extend a `test_hwconfig`/`test_cfgspec` assertion that the default exists if that file tests bindings defaults.
- [ ] **Step 9: Run → pass** — `run_some.sh tests.test_backend tests.test_flight`.
- [ ] **Step 10: Commit** — `git commit -m "feat(fcs): publish compassHeading (true 0-360 bearing) in the snapshot"`

**Migration note (carry to the finalize task, not code):** the FCS's `compassSign` must be calibrated for the single shared navtable so a clockwise turn increases the bearing — the value the old NAV `navtable.sign` held. Verified in-world in the FINAL task.

---

### Task 3: UI — attitude from the snapshot; delete the local attitude poll

**Files:**
- Modify: `ui/basalt/app.lua` — `M.buildState` (`pitch/roll/sas` source); delete scheduled task **(f)** (the ~0.1 s attitude poll).
- Test: `tests/test_basalt_app.lua` (buildState), `tests/test_page_pfd.lua` (already asserts attitude via `buildState`/rx — keep green).

**Interfaces:**
- Consumes: `runtime.rx:latest()` now carries `pitch, roll, surgeVel` (Task 1).
- Produces: `buildState(runtime, now).pitch/roll/sas` sourced from the snapshot; `sas = latest.surgeVel`.

- [ ] **Step 1: Failing test** — in `tests/test_basalt_app.lua`, extend the buildState test so attitude comes from `runtime.rx`, not `runtime.state`:

```lua
t.test("buildState sources pitch/roll/sas from the FCS snapshot (rx), not a local poll", function()
  local runtime = {
    rx = { latest = function() return { pitch = 0.1, roll = -0.2, surgeVel = 5 } end },
    engine = { status = function() return {} end }, hbRx = { up = function() return true end },
    state = { pitch = 99, roll = 99, sas = 99, pumpFrac = 0, tankFrac = 0 },  -- must be IGNORED now
    nav = {}, uiRev = 1,
  }
  local s = BasaltApp.buildState(runtime, 1000)
  t.eq(s.pitch, 0.1); t.eq(s.roll, -0.2); t.eq(s.sas, 5)
end)
```

- [ ] **Step 2: Run → fail** (`s.pitch` == 99 from `runtime.state`).
- [ ] **Step 3: Implement** — in `M.buildState`, change the three attitude lines from `runtime.state.*` to the snapshot (`latest` is the local `runtime.rx:latest()` already computed at the top of buildState):

```lua
    pitch        = latest.pitch,
    roll         = latest.roll,
    sas          = latest.surgeVel,
```

- [ ] **Step 4: Delete the attitude poll** — remove the entire `basalt.schedule(function() ... end)` block for task **(f)** in `M.startScheduled` (the "attitude poll, ~0.1s" loop). Remove now-dead `runtime.state.pitch/roll/sas` writes only; leave `runtime.state.pumpFrac/tankFrac/...` (fuel) intact.
- [ ] **Step 5: Run → pass** — `run_some.sh tests.test_basalt_app tests.test_page_pfd`. Fix any test that assumed the local poll wrote `runtime.state.pitch` (update it to inject via `rx`).
- [ ] **Step 6: Commit** — `git commit -m "refactor(ui): attitude from the FCS snapshot; delete the local attitude poll"`

---

### Task 4: UI — display heading from the snapshot (compassHeading)

Today `buildState.heading = navFresh and runtime.nav.heading` (the NAV `navhdg` relay). Switch it to the FCS snapshot's `compassHeading`, with the same freshness/`"---"` behavior driven by the telemetry link.

**Files:**
- Modify: `ui/basalt/app.lua` — `M.buildState` heading source; the freshness gate.
- Test: `tests/test_basalt_app.lua` / `tests/test_page_pfd.lua`.

**Interfaces:**
- Consumes: `runtime.rx:latest().compassHeading` (Task 2).
- Produces: `buildState(...).heading = compassHeading` when telemetry is live, else `nil` (→ tape shows "---").

- [ ] **Step 1: Failing test** — in `tests/test_basalt_app.lua`:

```lua
t.test("buildState heading comes from the FCS snapshot compassHeading", function()
  local runtime = {
    rx = { latest = function() return { compassHeading = 128 } end },
    engine = { status = function() return {} end }, hbRx = { up = function() return true end },
    state = { pumpFrac = 0, tankFrac = 0 }, nav = { heading = 999 },  -- nav.heading must be IGNORED
    uiRev = 1,
  }
  t.eq(BasaltApp.buildState(runtime, 1000).heading, 128)
end)
```

- [ ] **Step 2: Run → fail** (heading is 999 or nil from `runtime.nav`).
- [ ] **Step 3: Implement** — in `M.buildState`, replace `heading = navFresh and runtime.nav.heading or nil` with `heading = latest.compassHeading`. If the existing telemetry-staleness gate blanks the snapshot when the link is down, ensure `heading` follows it (a stale `latest` → nil). Keep the `"---"` render behavior in the PFD tape (unchanged — it already renders nil as dashes).
- [ ] **Step 4: Run → pass** — `run_some.sh tests.test_basalt_app tests.test_page_pfd`. Update the existing "heading from a FRESH nav relay" test to the new source (it now reads from `rx`, not `runtime.nav`).
- [ ] **Step 5: Commit** — `git commit -m "refactor(ui): display heading from the FCS snapshot compassHeading"`

---

### Task 5: UI — rate-limit the fuel poll (0.5 s → 3 s)

**Files:** Modify `ui/basalt/app.lua` — scheduled task **(c)** fuel poll.

- [ ] **Step 1:** Change `sleep(0.5)` at the end of the **(c)** fuel poll loop to `sleep(3.0)`. Update the comment `-- (c) fuel poll, 0.5s.` → `-- (c) fuel poll, 3s.` (No behavior test exists for the interval; this is a constant. If `test_basalt_app` asserts the schedule composition, keep it green.)
- [ ] **Step 2:** Run `run_some.sh tests.test_basalt_app` → PASS.
- [ ] **Step 3: Commit** — `git commit -m "perf(ui): fuel poll 0.5s -> 3s"`

---

### Task 6: NAV — drop the navtable read + navhdg relay; consume compassHeading from the FCS

NAV today reads its own navtable (`R:heading`), relays `navhdg` (`R:headingFrame`/`stepHeading`, `nav/app.lua` loop b1 at ~80 ms), and shows heading on its own status UI (`R:status`). We remove the navtable read and the `navhdg` relay; NAV opens the FCS telemetry channel (101) and reads `compassHeading` from the snapshot for its own status. The UI now gets heading from the FCS directly (Task 4), so it no longer needs `navhdg`.

**Files:**
- Modify: `nav/runtime.lua` — `R:heading` (source = FCS snapshot instead of navtable); remove `R:headingFrame`/`R:stepHeading` usage; `R:status` heading via the snapshot.
- Modify: `nav/app.lua` — open FCS telemetry ch 101 + route the snapshot into `runtime.nav`'s heading store; delete the fast heading-relay loop (b1); remove navtable wrap/discovery.
- Modify: `ui/basalt/app.lua` `routeModem` — the `navhdg` branch is now dead for display heading; remove or leave inert (heading comes from `rx`). Keep the `navfix` branch (GPS).
- Test: `tests/test_nav_runtime.lua`, `tests/test_nav_ui.lua`, `tests/test_basalt_app.lua`.

**Interfaces:**
- Consumes: FCS snapshot `compassHeading` on ch 101 (the same telemetry NAV now opens).
- Produces: NAV relays only `navfix` (GPS). `R:heading(snapshot)` returns `snapshot.compassHeading` (number|nil). No navtable peripheral access anywhere in NAV.

- [ ] **Step 1: Failing test (nav runtime)** — rewrite the "heading reads the navigation_table" test in `tests/test_nav_runtime.lua` to the new source: heading comes from an injected FCS snapshot, and a runtime built with **no navtable** still yields heading. Concretely, make `R:heading` take the latest FCS snapshot (inject it) and return its `compassHeading`:

```lua
t.test("heading comes from the FCS snapshot compassHeading, no navtable read", function()
  local rt = newRuntime(now, fakeDev(), nil)   -- NO navtable
  rt.fcsSnap = { compassHeading = 47 }          -- however the runtime stores the last snapshot
  t.eq(rt:heading(), 47)
end)
```
Adapt to the runtime's chosen snapshot-store field name — define it in this task and use it consistently (`self._fcsSnap`, set by the ch-101 route in `nav/app.lua`).

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement (nav/runtime.lua)** — `R:heading` returns `self._fcsSnap and self._fcsSnap.compassHeading or nil`; delete the navtable pcall. Add a setter `R:onFcsSnapshot(snap)` that stores `self._fcsSnap = snap`. `R:status` heading now flows from `R:heading` (unchanged call site). Delete `R:headingFrame`/`R:stepHeading` (or keep the functions but stop calling them — prefer delete + drop their tests).
- [ ] **Step 4: Implement (nav/app.lua)** — open ch **101** on the wired modem; in the modem-message router, when a telemetry frame arrives, call `runtime.nav:onFcsSnapshot(snap)`. Delete the fast heading-relay scheduled loop (b1, the `stepHeading` sleep loop). Remove the navtable discovery/wrap (`nav/app.lua:106`, and the navtable dep threading). Keep the GPS-fix relay loop and the GPS-beacon receiver untouched.
- [ ] **Step 5: Implement (ui/basalt/app.lua)** — in `routeModem`, remove the `navhdg` handling (or leave it storing `runtime.nav.heading` but unused). Heading for display now comes from `rx` (Task 4). Keep `navfix`.
- [ ] **Step 6: Run → pass** — `run_some.sh tests.test_nav_runtime tests.test_nav_ui tests.test_basalt_app`. Update `test_nav_ui`/signature tests that assumed a navtable-sourced heading to inject via the snapshot instead. Delete tests for the removed `stepHeading`/`headingFrame`.
- [ ] **Step 7: Commit** — `git commit -m "refactor(nav): drop navtable read + navhdg relay; take heading from the FCS snapshot"`

---

### Task 7: E2E — assert the network-traffic profile

A headless multi-role harness that runs FCS + UI + NAV logic against **mock modems that record every frame sent**, ticks them over a simulated window, and asserts the only traffic while the FCS runs is: FCS telemetry (ch 101), UI fuel poll (a 3 s cadence — assert no sensor reads, not a modem frame), NAV GPS-fix relay + beacon receipt, and FCS↔UI control comms only on a control-button edge. No UI/NAV sensor peripheral calls; renders only through the dirty gate.

**Files:**
- Create: `tests/test_comms_hygiene_e2e.lua`
- Reference: `tests/test_cockpit_assembly.lua` (mock-modem/newRuntime pattern), `tests/test_basalt_app.lua` (`newMockModem`), `tests/test_nav_runtime.lua` (nav runtime + fake dev).

**Interfaces:**
- Consumes: `newMockModem()` (records `transmit`), the UI/NAV/FCS runtime builders from the referenced tests, a **counting `wrap`** that increments a per-method counter on every sensor peripheral call.

- [ ] **Step 1: Write the harness + failing assertions.** Build a counting wrap: `local calls = {}; local function wrap(name) return setmetatable({}, { __index = function(_, m) return function(...) calls[m] = (calls[m] or 0) + 1 end end }) end`. Stand up the UI runtime (`M.buildRuntime` with this wrap + a mock modem), run its scheduled tasks for a simulated ~1 s window WITHOUT touching real peripherals (drive the schedule functions directly / a fake `sleep`), and assert:

```lua
-- UI made NO attitude sensor calls (poll deleted), only fuel reads:
t.eq(calls.getAngles or 0, 0, "UI must not read the gimbal")
t.eq(calls.getVelocity or 0, 0, "UI must not read velocity sensors")
t.eq(calls.getRelativeAngle or 0, 0, "UI must not read the navtable")
t.truthy((calls.getFuelAmountMb or 0) >= 1, "UI still reads engine fuel")
```
Add NAV assertions: with the nav runtime given no navtable, `calls.getRelativeAngle == 0`, and NAV emits `navfix` frames but zero `navhdg` frames (inspect the mock modem's recorded frames by `.k`).

- [ ] **Step 2: Run → fail** (before Tasks 3/6 land the poll/relay deletions the counts are non-zero — but since those tasks precede this, the failures here should only reflect harness bugs; iterate until the harness is correct and green).
- [ ] **Step 3: Make it green** — fix harness wiring only (production is already changed by Tasks 1-6). The assertions encode the acceptance goal.
- [ ] **Step 4: Add the module to `tests/run_headless.sh`'s suite list** (and the dist runner if separate).
- [ ] **Step 5: Commit** — `git commit -m "test(e2e): assert the sensor-comms traffic profile (no UI/NAV sensor polling)"`

---

### Task 8: Finalize — full suite, build, checkpoint

**Files:** manifests, `dist/`, memory/docs.

- [ ] **Step 1:** `node tools/build.mjs` (rebuild dist) then `bash tools/run_gen.sh` (regen manifests).
- [ ] **Step 2:** `bash tests/run_headless.sh` → must be fully green (0 failed). Fix any stragglers.
- [ ] **Step 3:** `node tools/render/audit_sizing.mjs` clean (no UI regressions), if any UI files changed layout (they shouldn't here).
- [ ] **Step 4:** Commit dist+manifests: `git commit -m "build: dist + manifest for comms-hygiene"`.
- [ ] **Step 5 (human/in-world, note for the operator):** verify the FCS `compassSign` so a clockwise turn increases the displayed bearing (the old NAV `navtable.sign` value); confirm PFD attitude + heading track live off telemetry with the FCS attached; confirm loopHz holds. This is the acceptance gate before merging to `main`.
- [ ] **Step 6:** Leave `main` untouched; the branch merges only on the operator's in-world acceptance.

## Self-review notes (author)

- Spec §4.1 (pitch/roll/surgeVel + compassHeading) → Tasks 1-2. §4.2 (NAV) → Task 6. §4.3 (UI attitude + SENS SOURCE) → Task 3 (poll deleted; live attitude is snapshot-only, so `SENS SOURCE=SELF` is calibration-only per the approved spec — the SELF-cal BIT/CONFIG procedure already reads on demand, so no code change is required there; confirm in Task 3 review that nothing else calls `senssource.readAttitude` in the background). §4.4 (fuel) → Task 5. §6 (e2e) → Task 7.
- Heading turned out deeper than the spec's one-liner (radians control-heading vs degrees compass; `navhdg` relay + NAV's own status UI + compass-sign migration). Captured in Task 2 + Task 6; the `SENS SOURCE`/NAV-sign-cal UIs become partly vestigial — a follow-up cleanup, not this plan.
- Type consistency: `compassHeading` (degrees, [0,360)) and `surgeVel`→`sas` mapping are used identically across Tasks 1-4, 6-7.
