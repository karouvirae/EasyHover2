# EasyHover 2 — CPL / DCPL Flight Modes

**Date:** 2026-08-14
**Status:** Approved design, pre-implementation
**Backup checkpoint:** tag `pre-cpl-dcpl` (to cut before build); fallbacks `pre-flight-modes`,
`manual-flight`, `stable-hover` behind it.

## Context

The flight-mode framework shipped 2026-08-13 (`2026-08-13-eh2-flight-modes-design.md`) added
selectable modes PRECISION / MAN / CRUISE on a pluggable-scheme registry. This spec adds two
more — **CPL (coupled)** and **DCPL (decoupled)** — a plane/jet-style flight feel with rich
pilot control over every axis.

They extend the exact same seams the last cycle proved: a mode is a scheme injected into
`fcs/runtime/loop.lua` via an O(1) `setActive` swap, selected by the dormant-then-wired
`flightMode` command/telemetry path in `fcs/runtime/flight.lua`, and driven by a pilot
`policy` from `fcs/modes/registry.lua`. CPL/DCPL **wrap the frozen
`fcs/schemes/level_flight.lua` (PRECISION) core** exactly like `manual.lua` / `cruise.lua` —
**zero flight-calibrated control math is copied or touched.**

### Priorities (user-ranked, drive every trade-off)
1. **Responsiveness** — modes add **zero delay** to any control calculation or command.
2. **Core-FCS preservation** — cannot regress the proven FCS or force a checkpoint rollback.
3. **Config cleanliness** — clean, separated per-mode config, merging what's sensible.

### Forward-looking (NOT built this cycle)
The user intends CPL/DCPL to eventually become **master modes** layered on top of a flight
mode (pick a master *and* a flight mode). For now they are plain registry modes alongside
PRECISION/MAN/CRUISE. Keep the scheme/policy boundaries clean so that split is cheap later.
**YAGNI** on the master-mode system now.

## Goals / Non-goals

**Goals**
- Two new selectable modes, **CPL** and **DCPL**, sharing one plane-style keymap and behavior,
  differing only in horizontal-drift handling.
- A per-mode keymap (the CPL layout overrides today's WASD) with clean per-mode switching.
- Auto-trim (surge→pitch) with a permanently-visible **UP/DN child button** on the FCS page.
- Per-mode tuning seeded from proven values, zero calibration loss, PRECISION untouched.
- A 5-mode cockpit selector that stays readable on the narrow merged-flight region.

**Non-goals (this spec)**
- The master-mode layering system (forward-looking, above).
- PRECISION stays the boot default — CPL/DCPL are opt-in per flight.
- Live tuning reload — gains stay frozen-at-boot (config is load-time only, unchanged).
- Any change to PRECISION / CRUISE behavior. (MAN gets one small pitch-direction fix, below.)

## Input mapping (CPL and DCPL share the same keymap)

| Key | Action | Notes |
|-----|--------|-------|
| **L-Shift** | Forward throttle | Ramp thrust up while held; **release → coast to idle**; routes to MAIN |
| **Space** | Cushioned brake | Decel demand ∝ current forward speed; tapers to 0 — never reverses |
| **W** | Pitch **down** (nose down / dive) | |
| **S** | Pitch **up** (pull up / climb) | |
| **A / D** | Roll left / right | Auto-levels on release |
| **Q / E** | Yaw — **rear-only rudder** | New mixer route |
| **, / .** | Yaw — **full differential** (front+rear) | Existing symmetric `mixYaw` route |
| **R / F** | Climb / descend | **Rampable**: tap = fine nudge, hold accelerates rate |
| **↑ / ↓** | Slow surge fwd / back | Fine positioning, slower than throttle/brake |
| **← / →** | Strafe left / right | Direct sway |

- **CPL-specific keymap variant** in `fcs/input/keymap.lua`, swapped in when CPL/DCPL is
  active. Today there is one global `keymap.default`, used once in `tools/flight.lua`, and
  **no per-mode switching** — add that wiring (the active map follows the selected mode's
  policy). PRECISION/MAN/CRUISE keep today's keymap untouched.
- **Related fix (approved):** flip **MAN** pitch arrows so **↑ = nose down, ↓ = nose up**
  (currently reversed) for craft-wide pitch consistency. 2-line keymap change; MAN is
  otherwise unchanged.

## Modes & behavior (user-approved)

**Shared by CPL and DCPL:**
- **Attitude** — W/S (pitch) and A/D (roll) feed tilt setpoints that ramp while held and
  **auto-level on release** (reuse MAN's `toward()` ramp + `tiltCap`/`tiltRate`). Altitude and
  heading are always PID-held.
- **Forward throttle (L-Shift)** — a direct forward-thrust demand injected into `d.surge`,
  ramps up while held, **decays to idle on release** (a CRUISE-style throttle that bleeds down
  instead of latching). Feel: `throttleRate`, `throttleDecay`.
- **Cushioned brake (Space)** — decel demand `∝ max(0, surgeVel)`, floored at 0 so it tapers
  to a stop and can never push backward. Feel: `brakeGain`, `brakeMax`.
- **Fine translate (arrows)** — slow surge (↑↓) + strafe (←→), lower rate than throttle/brake.
  Feel: `slowSurgeRate`, `strafeRate`.
- **Yaw** — Q/E → rear-only route (rudder feel); `,`/`.` → existing symmetric differential
  (pure torque). Both drive the heading loop.
- **Rampable climb (R/F)** — add hold-duration state (`climbHeld`): tap = small altitude
  nudge, sustained hold accelerates the rate. Feel: `climbRateMin/Max`, `climbRampTime`,
  `climbStep`.
- **Auto-trim coupling** — as forward thrust ramps, feed a gradual pitch offset to keep the
  nose straight against accel-induced pitch; direction from the UP/DN child button, **clamped
  inside the attitude limit**. Feel: `trimGain`, `trimDir` (default **DN** = nose-down
  correction for this craft's nose-up-under-accel tendency; button flips it per craft config).

**The one difference — horizontal drift:**
- **CPL** — when surge/strafe are **not** commanded, the FCS **velocity-damps the craft to a
  gentle stop** (the "cushion") and loosely holds it there. Release everything → it settles.
- **DCPL** — that damping is removed **on surge + sway only**; horizontal **momentum coasts
  on**. Pitch/roll still auto-level and altitude/heading still hold.

**Switching** — any mode, anytime, via the cockpit selector; safe one-shot transitions
(entering centers tilt / zeroes throttle / resets the incoming scheme, reusing the existing
`setActive` + `setMode` discipline).

## Architecture — one scheme per mode, wrapping the frozen core

Same pattern the flight-modes cycle chose (fastest hot path P1, strongest core preservation
P2, clean per-mode config P3).

### Frozen / shared / new
- **Frozen, untouched:** `fcs/schemes/level_flight.lua` (PRECISION), the control primitives
  (`fcs/control/pid.lua`, `heading.lua`, `translate.lua`), envelope, filter.
- **Shared, one addition:** `fcs/mixer/level_flight.lua` — add a **rear-only yaw route**
  (e.g. a `d.yawRear` demand → rear lateral pair only) alongside the untouched symmetric
  `mixYaw`. No change to existing lift/sway/surge/full-yaw mixing.
- **New, additive:**
  - `fcs/schemes/coupled.lua`, `fcs/schemes/decoupled.lua` — wrap `Level` like
    `cruise.lua`/`manual.lua`: `inner:update()`, then post-process the demand table (add the
    trim offset to `d.pitch`, route rudder to `d.yawRear`). **Surge/sway blend — the
    CPL/DCPL distinction:** when the pilot **is** commanding a horizontal axis (throttle,
    brake, slow-surge, or strafe), the pilot demand **overrides** that axis's inner output
    (same override idea as CRUISE's `d.surge = sp.surgeThrottle`). When the pilot is **not**
    commanding it: **CPL falls back to the inner `Level` translate output** (velocity-damped
    hold at the current position = the cushion); **DCPL forces that axis to 0** (no arrest →
    momentum coasts). Because the inner core is honored verbatim, `level_flight.lua` needs
    no edit.
  - `fcs/modes/registry.lua` — two new `SPECS` rows binding each ctor to its policy
    (`{ tilt=true, surge="coupled" }`). Built once at boot; runtime selection stays an O(1)
    descriptor swap (no per-cycle branch/alloc/IO).

### Command / telemetry path (already present, id-agnostic)
`fcs/runtime/flight.lua` `handleCommand{k="flightMode", id}` → `loop:setActive(d)` +
`pilot:setMode(d.policy, d.feel)` + `self.flightMode = id`; unknown id stays put. `snapshot`
already emits `flightMode`. `app.lua`/`cadence.lua` already carry it. **No edits** once
CPL/DCPL exist in the registry. Boot default stays **PRECISION**.

## Pilot / input — all in `fcs/input/`, no core-loop touch

- `keymap.lua` — CPL keymap variant (per the table); MAN pitch flip.
- `pilot.lua` — new `surge=="coupled"` policy branch plus new state fields in
  `Pilot.new`/`setMode` (`climbHeld`, throttle accumulator, trim). Produces: throttle
  ramp+decay, cushioned brake from `meas.surgeVel`, slow-surge/strafe setpoints, rampable
  climb, surge→pitch trim (signed by `trimDir`, re-clamped to `tiltCap`), and — for CPL — the
  drift-damp term that DCPL omits. New feel params arrive via `setMode(feel)`.
- `tools/flight.lua` — per-mode keymap switching wiring (select the active map from the mode).
- `config.lua` / feel — per-mode feel params live authoritatively in `tuningdefaults` (below).

## Config — per-mode tuning, shared calibration

- `fcs/io/tuningdefaults.lua` — add `DEFAULTS.modes.CPL` and `.DCPL`, each seeded from base
  `gains`/`caps`/`feel` (MAN/CRUISE pattern), then the new feel params: `throttleRate`,
  `throttleDecay`, `brakeGain`, `brakeMax`, `slowSurgeRate`, `strafeRate`, `climbRateMin`,
  `climbRateMax`, `climbRampTime`, `climbStep`, `trimGain`, `trimDir`.
- Rides the existing additive `cfgspec` merge → **no schema change, zero calibration loss,
  PRECISION records untouched**. `fcs/tuning.lua` `forMode()` resolves the new ids generically.
- **Stays single / shared (NOT per-mode):** hardware bindings (`eh2_devbind`) and sensor
  calibration (`eh2_senscal`) — craft calibration, not per-mode feel.

## Regression guard (the P2 insurance)

- **Golden test** (source + dist headless): PRECISION per-thruster outputs byte-identical;
  wrapping the frozen core means CPL/DCPL cannot regress it. Add golden captures for
  CPL/DCPL demand tables over an input battery.
- **Mode-isolation:** mutating CPL/DCPL config cannot change PRECISION outputs.
- **Registry fallback:** unknown `flightMode` → stay / PRECISION; boot default always PRECISION.

## UI — 5-mode selector + auto-trim child button

- Add `CPL`, `DCPL` to `M.MODES` (`ui/panels/fcs.lua:123`) → feeds both selector surfaces.
  Five modes now: **short labels** `PRE / MAN / CRU / CPL / DCP`; **wrap the narrow ~14-col
  merged-flight region selector to two rows** (`ui/basalt/regions/fcs.lua:86-92`); the wider
  standalone FCS page (`ui/basalt/pages/fcs.lua`) may stay one row. Update the
  `elements.modeBtns` map (`pages/fcs.lua:196-200`).
- **UP/DN auto-trim child button — permanently visible on the FCS mode section** of the
  standalone FCS page. Two-state toggle via `ui/basalt/switchbtn.lua` + relabel-on-click,
  bound to the active mode's `trimDir`; **no-optimistic-UI** — reflects reported state.
- **No-optimistic-UI** green-when-reported is automatic via existing `apply(state)`.
- Keep the derived-state MODE line (NORMAL/GROUND/DAMPED/PARKED) labeled distinctly from the
  mode selector.

## Config UI (per-mode tuning) — `ui/basalt/bitconfig/`

- `tuning.lua:175` — add CPL/DCPL to `M.MODES` (auto-generates cat/gains/caps/feel/help
  screens); `MODE_EXTRA_ROWS.CPL/.DCPL` for the new stepper feel params; register `HELP_IDS`.
  Keep each mode's FEEL extras ≤ ~8 rows so `edit_<mode>_FEEL_extra` fits the ~12-row monitor
  (routes through the existing BASE/MODE FEEL split).
- `trimDir` is a two-state enum, not a stepper — it does **not** go in `MODE_EXTRA_ROWS`; it
  is the FCS-page child button above. (Config-page tuning covers the numeric feel params.)
- `configkit.lua` GLOSSARY — CPL/DCPL entries + help for the new params (`throttle`, `brake`,
  `climbramp`, `autotrim`/`trimdir`), reachable via `HELP_IDS`.

## Testing

- `bash tests/run_headless.sh` (source) — full suite incl. new **golden** + **mode-isolation**
  tests and units mirroring `test_pilot_modes` / `test_modes_registry` / `test_flight_modes`:
  CPL cushion damps velocity→0; DCPL preserves surge/sway momentum; brake tapers & never
  reverses; auto-trim sign follows the UP/DN toggle and stays within the attitude limit;
  rampable climb accelerates with hold time; rear-only yaw hits only the rear pair; full yaw
  unchanged; CPL keymap swaps in/out on mode select; MAN pitch flip.
- **Fit test** for the 5-mode selector on the real ~14×12 region (config-UI-overhaul lesson:
  assert against the small frame, not the wide headless terminal).
- `bash tests/run_headless_dist.sh` — release gate vs minified `dist/`.
- Minify + manifest: `node tools/build.mjs` → `bash tools/run_gen.sh` (both channels) →
  `bash tools/run_gen.sh --check` (IN SYNC). New `fcs/` files enter the fcs-role closure; new
  UI logic the ui-role closure → both manifests regenerate.
- `bash tests/run_suite_e2e.sh` — 11-phase real install/update/repair.
- **In-game (test pilot):** update FCS+UI via the suite; CPL — L-Shift throttle / Space
  cushioned brake / W-S pitch / A-D roll / Q-E rudder / `,`-`.` full yaw / R-F rampable climb /
  arrows fine translate; auto-trim keeps the nose straight and the UP/DN button flips it; CPL
  cushions to a stop on release; DCPL — horizontal momentum coasts while attitude+altitude
  hold; MAN pitch now reads correctly; the 5-mode selector is readable on the merged region;
  loop stays ~15–20 Hz.

## Rollout

Ship per the release workflow: regenerate both manifests → commit source + `dist/` + both
manifests together → push `main`. Both **fcs** and **ui** roles change, so both must be
updated in-game.

## Risks & mitigations

- **Shared-mixer change (rear-only yaw) regresses PRECISION** → golden test is the hard gate;
  the new route is additive (new demand field), existing mixing untouched.
- **Mid-air transition transient** → one-shot enter reset (center tilt, zero throttle,
  `scheme:reset()`) at the switch instant.
- **Hot-path regression** → mode logic is O(1), no peripheral IO, all built at boot; verified
  by the in-game LOOP Hz readout.
- **Keymap-switch confusion** (WASD means different things per mode) → intended; documented in
  the mode help/glossary; PRECISION/MAN/CRUISE keymap unchanged so only CPL/DCPL differ.
