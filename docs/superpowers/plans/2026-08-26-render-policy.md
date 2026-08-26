# Per-Panel Render Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each cockpit panel its own render cadence — PFD on the knob, FLIGHT dirty-gated (blink-capable), PARAMS 1 Hz, NAV shell 3 s (heading dropped), everything else instant on interaction — instead of one shared clock re-painting every visible panel.

**Architecture:** A new pure `ui/basalt/renderpolicy.lua` owns the per-screen policy table + per-panel signatures. The UI gate consults it per visible frame (rate panels: apply on their own ms + own sig; event panels: skipped). Nav push/pop + interactions render immediately. The NAV PC shell slows to 3 s and drops heading.

**Tech Stack:** CC:Tweaked Lua, Basalt 2.0 full build, headless CraftOS-PC tests.

## Global Constraints
- Basalt **full build only**; NO peripheral/Basalt/fs access at module load; NO render-path peripheral polling (`apply()` reads cached state only).
- FCS shared render budget: streaming panels stay rate-limited; introduce no unconditional fast repaint.
- Preserve the FCS-missing blink EXACTLY: 2 Hz outline blink when the FCS heartbeat is stale, zero extra repaints when healthy.
- Policy map (authoritative): PFD-rate=`pfd`; Flight-rate(250 ms)=`flight`,`emc`,`fcs`; Params-rate(1000 ms)=`tuning`; Event(default)=`config`,`ap`,`nav`,`bitconfig`,`mdb`,`uical`,`senscal`,`senssource`,`pfdrate`,`dtc`,`fcssync`.

---

## File Structure
- Create: `ui/basalt/renderpolicy.lua` (policy table + per-panel sigs), `tests/test_renderpolicy.lua`.
- Modify: `ui/basalt/app.lua` (gate rewrite + immediate render), `ui/basalt/nav.lua` (push/pop callback), `nav/app.lua` (gate 3 s + sig heading drop), `nav/ui/main.lua` (drop heading row).
- Modify tests: `tests/test_basalt_app.lua`, `tests/test_cadence.lua` (if sig moves), `tests/test_nav_app.lua`/`tests/test_nav_main.lua` (whichever exist).
- `ui/basalt/cadence.lua`: keep `gate(prev,sig)` helper generic; per-panel sigs now live in renderpolicy.

---

## Task 1: renderpolicy module — policy table + per-panel signatures

**Files:**
- Create: `ui/basalt/renderpolicy.lua`
- Test: `tests/test_renderpolicy.lua`

**Interfaces:**
- Produces: `M.FLIGHT_MS=250`, `M.PARAMS_MS=1000`; `M.sigPfd(state)`, `M.sigFlight(state)`, `M.sigParams(state)` (each → string); `M.policyFor(screenId, pfdMs)` → `{mode="rate", ms, sig}` or `{mode="event"}`.
- Consumes: the flat `state` table `M.buildState` already produces (keys: pitch, roll, heading, target, linkUp, pumpAmount, tankMb, feeding, engaged, gndSafety, flightMode/mode, engineMaster, pulses, fcsStale, blinkPhase, comAuto/onGround/vSpeed/tankFrac, uiRev).

- [ ] **Step 1: Write failing tests** (`tests/test_renderpolicy.lua`), one behavior each:
  - `policyFor("pfd", 500)` → `{mode="rate", ms=500, sig=<M.sigPfd>}`; `policyFor("pfd", 250)` ms follows to 250.
  - `policyFor("flight")` / `"emc"` / `"fcs"` → `{mode="rate", ms=250, sig=M.sigFlight}`.
  - `policyFor("tuning")` → `{mode="rate", ms=1000, sig=M.sigParams}`.
  - `policyFor("config")`, `policyFor("nav")`, `policyFor("dtc")`, `policyFor("unknown")` → `{mode="event"}`.
  - `sigFlight` with `fcsStale=false` returns the SAME string for `blinkPhase=0` and `1` (phase folded to constant); with `fcsStale=true` returns DIFFERENT strings for phase 0 vs 1.
  - `sigPfd` changes when pitch changes but NOT when a fuel field changes; `sigFlight` changes when `pumpAmount` changes but NOT when `pitch` changes (per-panel isolation).
- [ ] **Step 2: Run tests, verify they FAIL** (`bash tests/run_headless.sh` or the module's test): expect "module not found" / assertion failures.
- [ ] **Step 3: Implement `ui/basalt/renderpolicy.lua`.** Pure module, no requires of Basalt/peripherals. Reuse `cadence.lua`'s `qn` quantizer style (nil-safe). `sigFlight` MUST fold blinkPhase: `(state.fcsStale and tostring(state.blinkPhase) or "-")`. Keep each sig limited to that panel's displayed keys.
- [ ] **Step 4: Run tests, verify PASS**, whole suite still green.
- [ ] **Step 5: Commit** `feat(ui): render policy table + per-panel signatures`.

## Task 2: UI gate rewrite — per-panel rate + dirty-gate; skip event panels

**Files:**
- Modify: `ui/basalt/app.lua` (scheduled task (e) `startScheduled`, and `applyState`/`M.run` wiring)
- Test: `tests/test_basalt_app.lua`

**Interfaces:**
- Consumes: `renderpolicy.policyFor`, `frameRec.nav:top()`, `M.showScreen`, `M.buildState`, `runtime.config.pfd.renderMs`.
- Produces: per-`frameRec` gate state `lastApplyAt`, `lastSig`.

- [ ] **Step 1: Write failing tests.** Inject a fake `frameRec`/`showScreen` seam:
  - A `frameRec` whose top is `flight`: gate calls `apply` only after `FLIGHT_MS` elapsed AND its sig changed; a second tick within `FLIGHT_MS` does not re-apply.
  - A `frameRec` whose top is `pfd` with `pfdMs=200`: applies at 200 ms cadence.
  - A `frameRec` whose top is `tuning`: applies at 1000 ms.
  - A `frameRec` whose top is `config` (event): gate NEVER applies it.
  - Per-panel isolation: with two frames (pfd + flight), a state change that alters only the PFD sig applies the pfd frame but NOT the flight frame.
- [ ] **Step 2: Run tests, verify FAIL.**
- [ ] **Step 3: Implement the gate.** Base poll `= math.min(pfdMs, renderpolicy.FLIGHT_MS)` recomputed each tick (knob may change live). Loop over `frameRecs`; for each, `pol = policyFor(top, pfdMs)`; if `pol.mode=="rate"` and `now-(rec.lastApplyAt or -inf) >= pol.ms`: `entry=showScreen(...)`; `sig=pol.sig(state)`; if `sig~=rec.lastSig` then `entry.handle.apply(state)`, `rec.lastSig=sig`; set `rec.lastApplyAt=now`. Keep the `uilog` RENDER timing probe. Remove the single global-sig `cadence.gate` call and the `extraDirty`/`navChanged` gate trigger (superseded; Task 3 handles nav immediacy).
- [ ] **Step 4: Run tests, verify PASS**, whole suite green.
- [ ] **Step 5: Commit** `refactor(ui): per-panel render gate (rate + own dirty-gate)`.

## Task 3: Immediate render on nav push/pop + interaction

**Files:**
- Modify: `ui/basalt/nav.lua` (push/pop post-change hook), `ui/basalt/app.lua` (`applyNow`, wire hook)
- Test: `tests/test_basalt_app.lua`, `tests/test_nav_stack.lua` (whichever holds nav-stack tests)

**Interfaces:**
- Produces: `Nav.new(opts)` accepts `opts.onChange` (called after push/pop with the new top); `applyNow(frameRec)` in `M.run` = `showScreen` + (rate top → `apply(buildState(now))`).
- Consumes: existing `M.showScreen`.

- [ ] **Step 1: Write failing tests.** `nav:push(x)` invokes `onChange` with the new top; `nav:pop()` invokes it with the revealed top. In app wiring, pushing a screen calls `showScreen` immediately (visible without waiting a gate tick); pushing a rate screen also calls its `apply` once immediately.
- [ ] **Step 2: Run tests, verify FAIL.**
- [ ] **Step 3: Implement.** Add the optional `onChange` to `nav.lua` (fire after the stack mutates, guarded so a nil callback is a no-op). In `M.run`, define `applyNow(frameRec)` and pass `onChange=function() applyNow(frameRec) end` when constructing each frame's nav. `applyNow` builds `state` once (`M.buildState(runtime, os.epoch("utc"))`), runs `showScreen`, and if the new top is a rate panel calls `apply(state)`; for event tops just `showScreen` (populate) — its widgets self-render on interaction. Reset that frame's `lastApplyAt/lastSig` so the gate re-baselines.
- [ ] **Step 4: Run tests, verify PASS**, whole suite green.
- [ ] **Step 5: Commit** `feat(ui): instant render on nav switch + interaction`.

## Task 4: NAV PC shell — 3 s cadence + drop heading

**Files:**
- Modify: `nav/app.lua` (gate (c) sleep, `M.signature`), `nav/ui/main.lua` (`viewModel` + heading widget)
- Test: existing `tests/test_nav_app.lua` / `tests/test_nav_main.lua` (add if absent)

**Interfaces:**
- Consumes: `runtime.nav:status`, `state.nav`.
- Produces: `M.signature` without heading; `viewModel` without `heading`/`headingTone`.

- [ ] **Step 1: Write failing tests.** `M.signature` of two states differing ONLY in `nav.heading` are EQUAL (heading no longer in the key); `viewModel(status)` has no `heading` field. A cadence constant test: the shell gate sleeps 3.0 s (assert the extracted constant, or that the loop uses `M.RENDER_S = 3.0`).
- [ ] **Step 2: Run tests, verify FAIL.**
- [ ] **Step 3: Implement.** In `nav/app.lua`: extract `M.RENDER_S = 3.0` and use it in the (c) gate `sleep`; remove the heading term from `M.signature`. In `nav/ui/main.lua`: delete the `heading`/`headingTone` from `viewModel` and remove/blank the heading widget, reflowing so position / fixInfo / quality / beacons stay laid out. Leave `useBaro` y-source + everything else intact.
- [ ] **Step 4: Run tests, verify PASS**, whole suite green.
- [ ] **Step 5: Commit** `refactor(nav): shell renders at 3 s, heading dropped`.

## Task 5: dist rebuild + manifest

**Files:** Modify: `release/` dist + manifest (per repo's build step).

- [ ] **Step 1:** Run the repo's dist/build script (mirror how prior commits built `dist`).
- [ ] **Step 2:** Run the full dist + e2e suite; verify green (source + dist parity).
- [ ] **Step 3: Commit** `build: dist + manifest for render policy`.

---

## Self-Review Notes
- Blink preserved: `sigFlight` folds blinkPhase to a constant when healthy (zero repaints), flips at 2 Hz when `fcsStale`; the flight poll (250 ms) is ≤ blink half-period (500 ms) so both phases render. (Task 1 + Task 2.)
- No-op when closed: rate panels are gated on being the visible `nav:top()`; `tuning` closed → never applied/polled. (Task 2.)
- Budget: base poll `min(pfdMs,250)`; `buildState` reads cached fields only, no peripheral. Streaming panels dirty-gated; instant renders are discrete. (Task 2 + 3.)
- Type consistency: `policyFor`/`sig*` names identical across Tasks 1–3; `M.RENDER_S` used in Task 4.
