# EasyHover 2 — Ground-idle (engaged-but-parked) design

- **Date:** 2026-08-09
- **Status:** approved (brainstormed + cleared with the pilot)
- **Scope:** one focused change to the FCS runtime state machine + one tuning param + telemetry field.

## Problem

When the FCS is engaged while the craft sits on the ground, it still commands hover
thrust (~hoverDuty) and P-corrections — the craft "fires" and can make small involuntary
hops, and the oscillation detector chews on idle ground-sensor noise (pitch/roll ≈ 0) and
false-trips DAMPED. There is no reason to actuate at all while parked. We want the FCS,
when engaged but sitting still on the ground, to output **zero thrust** and only wake up
when the pilot commands a climb (or the craft actually leaves the ground / starts moving).

## Rule

Evaluated every cycle while `engaged` (in `fcs/runtime/flight.lua`):

```
atRest = |vSpeed| < moveEps  AND  |swayVel| < moveEps  AND  |surgeVel| < moveEps
parked = onGround  AND  atRest  AND  NOT climbHeld
```

- **climbHeld** = the pilot's lift-up input (`held.up`, i.e. Space/R).
- **onGround** = the existing calibrated downward-optical signal already in `meas`.
- **moveEps** ≈ 0.5 blocks/s, from `fcs/tuning.lua` (`groundIdle.moveEps`). On the pad the
  velocity sensors read ~0; any real flight is well above 0.5 → clean separation with margin.
- Yaw rate is intentionally **excluded** from the motion test (spinning in place while parked
  shouldn't force firing; the terrain hazard is translational/vertical).

### Why the motion gate matters (the terrain case)

`onGround` is an absolute optical threshold, so flying **low over higher terrain** (a tree, a
hill) can flicker `onGround` true mid-flight. Requiring `atRest` as well means a craft that is
*moving* (high `surgeVel`/`swayVel`, or dropping with `vSpeed`) is treated as in-flight and the
controller stays live — no mid-air thrust cut. Only a genuinely settled, grounded craft parks.

## Behavior / lifecycle

- Engage while sitting on the pad → **silent** (no auto-hover, no attitude twitch).
- Press **climb** → un-parks → lifts off.
- Airborne (`onGround` false, or moving) → **fully active**.
- Land and let it settle (grounded + at rest + no climb) → **re-parks**, thrust cut, sits quietly.
- Shoved off the ground / pushed → `onGround` false or moving → **auto-activates**, catches it.

## Implementation

- **`fcs/runtime/flight.lua`** owns the decision (it already has `held` + engage state; the Loop
  stays a pure controller). Factor the decision into a single isolated predicate
  `Flight:_parked(held, meas)` so the next hardening (below) is a one-function change.
  - `Flight.new(deps)` gains `deps.moveEps` (default 0.5).
  - `Flight:step`: while engaged, if `_parked` → `pilot:reset(meas)` (hold setpoints at current,
    no ramp) + `loop:arm(false)` (engaged-but-idle: the disarmed loop already outputs zeros,
    resets the scheme/integrators, and does **not** run the oscillation detector). Else → normal
    `pilot:update` + `loop:arm(true)`.
  - Engage command sets `engaged=true` + `_needReset=true` only; **arming is decided in `step`**
    (so engaging on the pad is silent). Disengage sets `engaged=false`.
- **`fcs/tuning.lua`**: add `groundIdle = { moveEps = 0.5 }`.
- **`tools/flight.lua`**: pass `moveEps = tuning.groundIdle.moveEps` into `Flight.new`.

## Telemetry

`Flight:snapshot` gains `parked` (bool); reported `mode` reads `"PARKED"` when parked so the UI
shows the true state (no optimistic UI — consistent with the project rule).

## Side benefit

Kills the DAMPED false-trip: while parked the loop is disarmed, so the oscillation detector never
runs on idle ground noise.

## Known limitation → next iteration

Detection is `onGround` (absolute optical threshold) + a coarse motion gate. It is safe over flat
ground / the home pad and defends the moving-over-terrain case, but a craft **hovering slowly and
low over higher terrain** (grounded-reading AND at-rest AND no climb) could still false-park. The
isolated `_parked` predicate is where the next hardening lands: fuse barometric altitude vs. the
liftoff altitude, or require altitude ≈ engage-altitude, so "parked" means "at the height we took
off from," not merely "something close below." Out of scope for this change (pilot-agreed).

## Testing (headless, pure)

`tests/test_flight.lua` (fake loop) covers:
1. Engaged + onGround + at rest + no climb → loop **not armed** (parked); zero thrust.
2. Engaged + onGround + **climb held** → loop **armed** (un-park to lift off).
3. Engaged + onGround + at rest + no climb, but **|surgeVel| > moveEps** → loop **armed**
   (moving-over-terrain stays in-flight).
4. Engaged + **not onGround** → loop armed (airborne).
5. Snapshot reports `parked=true` / `mode="PARKED"` when parked.
6. Existing engage/disengage/gndSafety-gate tests still hold under the new arm-in-step model.

## Non-goals

- No new sensor, no relative distance capture (reusing calibrated `onGround`).
- No change to the control math, mixer, actuator, or the Loop's public interface.
- Baro/altitude fusion for uneven terrain (explicitly deferred to the next iteration).
