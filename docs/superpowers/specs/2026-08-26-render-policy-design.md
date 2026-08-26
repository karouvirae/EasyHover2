# Per-Panel Render Policy — Design

**Date:** 2026-08-26
**Status:** approved (user-specified conventions, 2026-08-26)

## Problem

Today the UI PC runs ONE render loop (`ui/basalt/app.lua` scheduled task (e)): it sleeps
`pfd.renderMs` (the operator's "PFD RATE" knob, currently 500 ms), builds ONE global state
signature (`ui/basalt/cadence.lua`), and — when that signature changes — calls `applyState`,
which re-applies **every currently-visible screen** on every monitor. Two consequences:

1. **The "PFD RATE" knob governs the whole UI, not just the PFD.** Because `showScreen` runs
   only inside `applyState` (on the gate), opening a submenu / seeing a toggle confirm waits for
   the next gate tick — up to 500 ms. Menus feel sluggish at the operator's PFD setting.
2. **One global signature means cross-panel repaint coupling.** When the PFD's attitude moves
   (every tick in flight), the global signature changes, so *every* visible panel — including a
   static config menu — gets re-applied and re-blit, even though only the PFD changed.

The NAV PC (`nav/app.lua` task (c)) has its own gate at 0.3 s; it streams position + heading +
beacons far faster than a rarely-watched diagnostic shell needs.

## Goal

Each visible panel renders on the cadence its content actually needs, dirty-gated on **its own**
data, and interaction-only menus render **immediately** on the click/keystroke rather than
waiting for a shared clock. The FCS's shared server render budget is protected: streaming panels
stay rate-limited; instant menu renders are discrete (one paint per action), so free.

## Conventions (authoritative)

Per-panel render **policy**, keyed by screen id:

| Policy | Screens | Cadence | Dirty-gate | Notes |
|---|---|---|---|---|
| **PFD-rate** | `pfd` | `runtime.config.pfd.renderMs` (the knob) | yes, PFD sig | The knob now affects **only** the PFD. |
| **Flight-rate** | `flight`, `emc`, `fcs` | `FLIGHT_MS = 250` ms poll | yes, flight sig | Slow when healthy (data changes rarely → few repaints); the poll only needs to be ≤ blink half-period so the FCS-missing blink renders. Blink → repaints at 2 Hz. That only happens when the FCS is down anyway. |
| **Params-rate** | `tuning` | `PARAMS_MS = 1000` ms (hardcoded, 1 Hz) | yes, params sig | Debug screen. Never applied by the gate while it is not the visible top → no render/update/poll when closed (which is most of the time). |
| **Event** | `config`, `ap`, `nav`, `bitconfig`, `mdb`, `uical`, `senscal`, `senssource`, `pfdrate`, `dtc`, `fcssync` | none | n/a | The gate never applies these. They render **immediately** on nav push/pop and their own field/button interactions. |

Default for any screen id not listed → **Event** (safe: gate never polls it).

**NAV PC shell** (`nav/app.lua` gate + `nav/ui/main.lua`):
- Render poll 0.3 s → **3000 ms** (3 s), still dirty-gated on `M.signature`.
- **Drop the heading row** from the shell display + its signature. Keep: GPS **position** (with
  baro-Y "B" / trilaterated-Y "N" suffix), **baro height** from the FCS snapshot, and GPS
  **beacon/constellation intel** (n beacons, age, quality, per-beacon status). Groundspeed is
  **already absent** from the shell (only relayed for the PFD) — nothing to remove there.

## Architecture

### New module: `ui/basalt/renderpolicy.lua` (pure, testable)
Owns the policy table AND the per-panel signatures (moved out of the monolithic `cadence.sig`):
```
M.FLIGHT_MS = 250
M.PARAMS_MS = 1000
M.sigPfd(state)    -> string   -- pitch, roll, heading, target cue, linkUp
M.sigFlight(state) -> string   -- fuel (coarse), feeding, engaged, gndSafety, mode, engineMaster,
                                  pulses, AND fcsStale + (fcsStale and blinkPhase or "-")
M.sigParams(state) -> string   -- comAuto status keys the tuning region shows (engineMaster,
                                  onGround, gndSafety, vSpeed sign/threshold, tankFrac, engaged,
                                  flightMode) + uiRev
M.policyFor(screenId, pfdMs) -> { mode="rate", ms=<n>, sig=<fn> } | { mode="event" }
```
`policyFor` resolves `pfd` → `{mode="rate", ms=pfdMs, sig=M.sigPfd}`; `flight`/`emc`/`fcs` →
`{ms=FLIGHT_MS, sig=M.sigFlight}`; `tuning` → `{ms=PARAMS_MS, sig=M.sigParams}`; else
`{mode="event"}`.

### UI gate rewrite (`ui/basalt/app.lua` task (e))
- Base poll = `min(pfdMs, FLIGHT_MS)` (so the blink is always serviced; PARAMS_MS is a multiple).
- Each tick: `state = buildState`; for each `frameRec`, get `top = nav:top()` and
  `pol = renderpolicy.policyFor(top, pfdMs)`. If `pol.mode == "rate"` AND
  `now - frameRec.lastApplyAt >= pol.ms`: ensure `showScreen`, compute `sig = pol.sig(state)`,
  and `apply(state)` only when `sig ~= frameRec.lastSig`; update `lastSig` + `lastApplyAt`.
  `mode == "event"` frames are skipped by the gate.

### Immediate render on interaction
`ui/basalt/nav.lua` `push`/`pop` gain an optional post-change callback. `app.lua` wires it to an
`applyNow(frameRec)` that runs `showScreen` + (if the new top is a rate panel) `apply(state)`
right then — so opening ANY panel (event or rate) and BACK is instant, not gated. Event panels'
own button/field callbacks already re-render their widgets via Basalt's native event pump; the
push-time `applyNow` covers the initial populate. The old `navChanged`/`extraDirty` path is
removed (superseded by immediate render + per-panel gating).

### NAV PC (`nav/app.lua`, `nav/ui/main.lua`)
- Gate (c): `sleep(0.3)` → `sleep(3.0)`; keep the `sig ~= lastSig` dirty-gate.
- `M.signature`: drop the heading term.
- `nav/ui/main.lua` `viewModel`: remove the heading field + the shell's heading widget; reflow so
  position / fixInfo / quality / beacons remain. (`useBaro` y-source logic unchanged.)

## Testing

Headless CraftOS + the existing test suite. New/updated tests:
- `tests/test_renderpolicy.lua`: `policyFor` mapping (each id → correct mode/ms/sig); `pfd` ms
  follows the passed `pfdMs`; unknown id → event; `sigFlight` folds blinkPhase to a constant when
  `fcsStale` is false and flips it when true; `sigPfd`/`sigParams` change only on their own keys.
- `tests/test_basalt_app.lua`: gate applies a rate panel only after its ms elapsed + sig change;
  skips event panels; a nav push renders immediately (applyNow called); a PFD-knob change does
  NOT force a flight repaint (per-panel sig isolation).
- `tests/test_nav_*`: NAV signature has no heading term; shell viewModel has no heading; gate
  cadence constant is 3.0.

## Global Constraints
- Basalt **full build only**; no peripheral/Basalt/fs access at module load.
- No render-path peripheral polling (unchanged rule). `apply()` reads cached state only.
- FCS budget: streaming panels stay rate-limited; do not introduce an unconditional fast repaint.
- Preserve the FCS-missing blink behavior exactly (2 Hz when stale, zero cost when healthy).
