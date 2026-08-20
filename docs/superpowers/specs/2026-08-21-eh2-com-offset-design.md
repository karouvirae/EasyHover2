# EH2 — CoM offset mixer + Auto COM trim

**Date:** 2026-08-21
**Status:** SHIPPED to main (`f2c405f`..`085ffcd`, HEAD later includes keypad fixes)
**Area:** `fcs/mixer/level_flight.lua`, `fcs/comauto.lua`, `fcs/runtime/flight.lua`, `ui/basalt/bitconfig/tuning.lua`

## Problem

The 4 lift thrusters are a rectangle (craft longer than wide). Payload / fuel shift the
Create: Simulated CoM off that rectangle's center. The mixer assumed a symmetric square
about geometric center. With pitch/roll `ki=0`, an off-center CoM settles as a **tilt**
(or the integral used to carry it). User wants the deck **flat**, no hover drift, and
accel/turn not dragging a bias.

Aeronautics diagram CoM is a **continuous** `Vector3d` (`logicalPose().rotationPoint()`);
there is no 0.1-block grid. 0.1 block is the **menu step**.

## Approach

**CoM-relative lift mix** (not an attitude setpoint bias). User types the offset in
blocks relative to the 4-lift rectangle. Mixer reweights FL/FR/RL/RR so heave-only has
zero net pitch/roll about that CoM. Same `p`/`r` demands still add attitude torque.

**Two spans** (rectangle, not square):

| Field | Meaning |
|-------|---------|
| `com.spanFwd` (SP FWD) | C → front/back **edge** (half-length), 90° |
| `com.spanRight` (SP LAT) | C → left/right **edge** (half-width), 90° — the red line in the user's sketch |
| `com.fwd` | CoM forward of C (blocks) |
| `com.right` | CoM right of C (blocks) |

Legacy single `com.span` still maps to both arms in `Mixer:setCom`.

Arms must stay > 0.05 or mix falls back to the old symmetric formula (byte-identical
when both spans unset/0). Offsets clamp to 0.9 × that axis arm.

`Mixer.offsetFromDuties(duties, {spanFwd, spanRight})` inverts a hover mix back to
fwd/right (used by Auto COM).

## Auto COM trim

BIT/CONFIG → FCS TUNING → COM → AUTO. Optional. Overwrites **FWD/RIGHT** (needs both
SPANs set). Stick ignored. After capture: auto-descend + disengage.

**Lamp:** red WAIT (next missing prereq) / green READY / blue RUN.

**Prereq order:** MDB bind (FL/FR/RL/RR + altimeter + gimbal) → SENS CAL (`signPitch` +
`signHeading`) → both SPANs ≥ 0.1 → ENG MASTER on → on ground → GND SAFE off → not
moving → liquid fuel ≥ 20% → FCS engaged → mode PRECISION or CPL.

**Procedure:** climb ~8 blk AGL → HOLD until level dwell → capture duties →
`mixer:setCom` live → DESCEND → DONE/disengage. Temporary pitch/roll `ki` only in HOLD.

**Abort** (descend, then disengage on ground): Abort button, DAMPED, |pitch|/|roll| >
0.15 rad, horizontal wander > 4 blk (surge/sway pos). Typewriter ignored while active.

Typed COM SAVE still applies on **FCS reboot** (same as all TUNING). Auto applies live
on the flying mixer and the UI writes `/eh2_tuning.tbl` when capture arrives.

## UI

FCS TUNING root: **COM** sibling next to PRECISION/MAN/CRUISE/CPL/DCPL. Steppers 0.1.
RST zeros FWD/RIGHT, keeps spans. AUTO opens the lamp/START/ABORT screen.

## Files

- `fcs/io/tuningdefaults.lua` — `com = {fwd,right,spanFwd,spanRight}`
- `fcs/mixer/level_flight.lua` — `setCom`, `offsetFromDuties`, `corners`
- `fcs/comauto.lua` — prereqs/lamp/procedure (PURE)
- `fcs/runtime/flight.lua` — `comAuto` start/abort, stick ignore, unpark, ki, capture
- `fcs/modes/registry.lua` — `mixer:setCom(tuning.com)` at boot
- `ui/basalt/bitconfig/tuning.lua` — COM + AUTO screens
- `ui/basalt/app.lua` — cadence `onGround`, `comAuto`

## Tests

`test_mixer`, `test_comauto`, `test_flight`, `test_tuningdefaults`, `test_bitconfig_tuning`.
1151/0 source+dist + e2e at SPAN split (`085ffcd`).

## NEXT (in-world)

Set SP FWD + SP LAT from the lift rectangle, SAVE, reboot FCS. Optional AUTO with
prereqs green. In-world tune if the mix fights the heavier craft.

**v1 limits:** laterals/surge not CoM-reweighted; no vertical CoM (jeep effect); Auto
COM is FCS+UI only (NAV unused for the wander leash).
