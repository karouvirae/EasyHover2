# EasyHover 2 — Flight Modes (Spec A)

**Date:** 2026-08-13
**Status:** Approved design, pre-implementation
**Backup checkpoint:** tag `pre-flight-modes` (`9ea0398`, pushed to origin); fallbacks
`manual-flight`, `stable-hover` behind it.

## Context

The EasyHover 2 FCS is flight-proven and stable (tag `manual-flight`). This spec adds the
long-deferred **selectable flight modes** — the pluggable-ControlScheme capability the FCS
core design (`docs/FCS_CORE_DESIGN.md` §8) always anticipated but never wired.

The seam already exists: `fcs/runtime/loop.lua` `Loop.new(cfg)` takes a duck-typed
`{scheme, mixer, ...}` pair and `Loop:cycle(dt, m)` calls `scheme:update(...)` →
`mixer:mix(...)` → `apply(...)`. `fcs/runtime/flight.lua` already carries a dormant
`flightMode` field, a `handleCommand{k="flightMode", id}` branch, and emits `flightMode` in
its telemetry snapshot — but nothing selects on it and no UI drives it. Two inert "MODE"
placeholder grids already sit in the UI (`ui/basalt/pages/fcs.lua`,
`ui/basalt/regions/fcs.lua`) waiting for exactly this.

### Priorities (user-ranked, drive every trade-off)
1. **Responsiveness** — modes must add **zero delay** to any control calculation or command.
2. **Core-FCS preservation** — this update and future mode updates must not be able to
   regress the proven FCS and force a checkpoint rollback.
3. **Config cleanliness** — clean, separated per-mode config, merging what's sensible for QoL.

## Goals / Non-goals

**Goals**
- Three selectable modes: **PRECISION** (today's flying, default), **MAN** (manual tilt),
  **CRUISE** (held forward throttle).
- A cockpit mode selector with a live, telemetry-reported active indicator.
- Per-mode tuning config, seeded from today's proven values with zero calibration loss.
- An automated regression guard that makes a PRECISION regression impossible to ship silently.

**Non-goals (this spec)**
- The config-page **readability overhaul** (FCS Tuning restructure, MDB/UI CAL/SENS CAL/DTC
  cleanup) — that is **Spec B**, a separate pure-UI cycle. Only the *mode selector* ships here.
- The deferred **"pitchable" propel/brake** scheme and any further modes — additive later on
  the same registry.
- Live tuning reload — gains stay frozen-at-boot (config is load-time only, unchanged).

## Modes & behavior (user-approved)

- **PRECISION** — today's flat/slow flying, **unchanged**. Auto-selected on fresh FCS boot;
  its selector button is green when active. The safe-takeoff / role default.
- **MAN** — attitude-stabilized, but the typewriter **arrow keys command a pitch/roll tilt
  angle** (proportional while held, **auto-levels on release**). **Horizontal position-hold
  relaxes** so the tilt actually translates the craft. Altitude + heading + attitude
  stabilization stay active; tilt caps relaxed vs PRECISION. Purpose: a test-bed for tilt
  ahead of future tilt-propulsion modes.
- **CRUISE** — identical to PRECISION on every axis **except surge**: W ramps the main
  thrusters up, **release holds that throttle level** (open-loop detent), S ramps back down.
  Forward speed then rides on drag.
- **Switching** — any mode, anytime, via cockpit button; **safe one-shot transitions**:
  leaving CRUISE zeros the held surge, entering PRECISION re-levels, entering MAN centers tilt.

## Architecture — separate scheme per mode, assembled from shared parts

Chosen to fit the priority ranking: fastest hot path (P1), strongest core preservation (P2),
clean per-mode config (P3). (Rejected: behavior-flags on one scheme — adds per-cycle branches
into the proven hot path; shared-core refactor — edits the proven path, parity rests on tests.)

### Frozen / shared / new
- **Frozen, untouched:** `fcs/schemes/level_flight.lua` = PRECISION.
- **Shared, unchanged:** `fcs/mixer/level_flight.lua` (same airframe — MAN tilt is just a
  nonzero attitude setpoint through the existing differential-lift authority; CRUISE surge is
  a held surge demand through the existing `mixSurge`), and the control primitives
  `fcs/control/pid.lua`, `fcs/control/heading.lua`, `fcs/control/translate.lua`, envelope,
  filter.
- **New, additive:**
  - `fcs/schemes/manual.lua`, `fcs/schemes/cruise.lua` — thin scheme assemblies that
    construct their own controllers **from the shared primitives** (copy **zero**
    flight-calibrated math). Because MAN builds its own attitude controllers and feeds them a
    pilot tilt setpoint, **`level_flight.lua` needs no edit**.
  - `fcs/modes/registry.lua` — maps `PRECISION | MAN | CRUISE` → a descriptor
    `{ id, label, default, scheme, mixer, caps, inputPolicy, onEnter, onExit }`. Built **once
    at boot**.

### Runtime selection (hot-path safe — P1)
- `fcs/runtime/loop.lua` gains `Loop:setActive(id)` — a **single reference swap**. `Loop:cycle`
  continues to call `activeScheme:update(...)` exactly as today: **no per-cycle branch, no
  allocation, no peripheral IO** introduced. All three schemes/mixers are built at boot; the
  hot path never constructs anything.
- Boot builds the registry in `tools/hover_test.lua` `buildLoop(backend)` (reused verbatim by
  `tools/flight.lua`), replacing the lone `Scheme.new` + `Mixer.new`. Default active =
  PRECISION.

### Command path (already present)
`fcs/runtime/flight.lua` `handleCommand{k="flightMode", id}` →
1. validate `id` against the registry (unknown → **stay put**, no-op);
2. run the current mode's `onExit` + the new mode's `onEnter` hook, and `scheme:reset()` the
   incoming scheme (the loop already resets schemes on disarm — reuse that discipline);
3. `Loop:setActive(id)`; set `self.flightMode = id`.

`snapshot` already emits `flightMode`. Rename the default `"NORMAL"` → `"PRECISION"`.

## Pilot / input — all in `fcs/input/`, no core-loop touch

- `keymap.lua` — add pitch/roll axes on the arrow keys (Up/Down = pitch, Left/Right = roll),
  **gated to MAN** (inert in other modes). WASD/QE/RF unchanged.
- `pilot.lua` — behavior driven by the active mode's `inputPolicy` (read from the registry):
  - MAN: emit `sp.pitch` / `sp.roll` (ramp-while-held, **auto-level-on-release**) and feed the
    horizontal loops the **measured** position each cycle (inert hold → tilt translates).
  - CRUISE: emit a **held surge-throttle** (W ramps up, release holds, S ramps down) in place
    of the leashed surge-position setpoint.
  - PRECISION: today's behavior, unchanged.
- `config.lua` / feel — per-mode feel params (tilt rate, tilt cap, cruise surge ramp rate).

## Config — per-mode tuning, shared calibration

- `eh2_tuning` gains a `modes.{PRECISION, MAN, CRUISE}` section, each a **full**
  gain/cap/feel record. **Additive migration seeds all three from the current proven tuning**
  (zero loss): today's values become PRECISION; MAN gets relaxed tilt caps and CRUISE gets
  surge-throttle params from defaults. Hooks into `fcs/io/tuningdefaults.lua` + the cfgspec +
  the existing migrator (`textutils.serialise` byte-parity discipline: clone through a fresh
  `cfgspec.defaults()` scaffold, overwrite existing keys only).
- **Stays single / shared (NOT per-mode):** hardware bindings (`eh2_devbind`) and sensor
  calibration (`eh2_senscal`) — craft calibration, not per-mode feel. (P3: only *tuning*
  splits; everything mergeable stays merged.)
- Per-mode **tuning UI** is deferred to Spec B; modes fly on seeded values without it.

## Regression guard (the P2 insurance)

- **Golden test** (headless; runs in both `tests/run_headless.sh` and
  `tests/run_headless_dist.sh`): capture today's PRECISION per-thruster duty outputs over an
  input battery (varied attitude/altitude/heading/translation measurements + setpoints) and
  assert the new PRECISION path reproduces them; **RED on any drift** from a shared-module
  change. Uses the `RecordingMixer` / `ConstantLoop` test doubles the FCS core design (§8)
  anticipates (build them if absent).
- **Mode-isolation test:** mutating MAN/CRUISE config provably cannot change PRECISION outputs.
- **Registry fallback:** unknown/invalid `flightMode` id → stay / PRECISION; boot default is
  always PRECISION.

## UI — mode selector only (rest of config UI = Spec B)

- Replace the inert placeholder MODE grids on `ui/basalt/pages/fcs.lua` (the
  `ALT HLD / HDG HLD / AUTO` row) and `ui/basalt/regions/fcs.lua` (the switch grid) with a
  live `PRECISION / MAN / CRUISE` selector, reusing `ui/basalt/switchbtn.lua`.
- **No-optimistic-UI:** the active button goes green **only when telemetry reports the mode
  changed**. Carry `flightMode` through `ui/basalt/app.lua` `M.buildState` and hash it in
  `ui/basalt/cadence.lua` `M.sig` (≈2-line adds each). Send `{k="flightMode", id}` on tap via
  the `ui/panels/fcs.lua` action factory.
- Keep the existing MODE **status line** (derived loop state NORMAL/GROUND/DAMPED/PARKED) and
  **label it distinctly** from the mode **selector** — they are different concepts (operating
  state vs selected scheme) and must not read as the same control.

## Testing

- `bash tests/run_headless.sh` — full suite incl. new **golden** + **mode-isolation** tests
  (source channel).
- `bash tests/run_headless_dist.sh` — release gate vs minified `dist/`.
- Minify + manifest: `node tools/build.mjs` → `bash tools/run_gen.sh` (both channels) →
  `bash tools/run_gen.sh --check` (IN SYNC). New `fcs/` files enter the **fcs-role** require
  closure and new UI logic the **ui-role** closure → both manifests regenerate.
- `bash tests/run_suite_e2e.sh` — 11-phase real install/update/repair.
- **In-game (test pilot):** boot → PRECISION auto-green; fly PRECISION unchanged; MAN →
  arrow-key tilt translates and auto-levels on release; CRUISE → W holds forward on release, S
  throttles back; switch modes mid-air safely; confirm loop stays ~15–20 Hz (no added delay);
  capture selector screenshots.

## Rollout

Ship per the release workflow: regenerate both manifests → commit source + `dist/` + both
manifests together → push `main`. Both **fcs** and **ui** roles change, so both must be
updated in-game.

## Risks & mitigations

- **Shared-primitive change regresses PRECISION** → the golden test is the hard gate; prefer
  adding PRECISION-neutral-default params to shared modules over changing existing behavior.
- **Mid-air transition transient** → one-shot `onEnter`/`onExit` hooks + `scheme:reset()`
  neutralize held state (surge, tilt, integrators) at the switch instant.
- **Hot-path regression (loop-rate collapse)** → mode logic is O(1) with no peripheral IO;
  everything built at boot; verified by the in-game LOOP Hz readout staying ~15–20 Hz.

## Deferred to Spec B (captured, next cycle)

Pure-UI readability overhaul of `ui/basalt/bitconfig/`: FCS Tuning → overview + drilldowns
(absorbing the per-mode selection); MDB-Conf / UI CAL / SENS CAL / DTC → separated buttons,
short **ASCII-safe** glyph labels (`X` decline, `<`/`<-` back, `OK` accept — verified against
the real CC:T font, not CraftOS-PC), readable labels, drilldowns, and a **BACK button on
UI CAL**. FCS SYNC stays as-is.
