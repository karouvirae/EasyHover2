# EasyHover 2 — Sensor Calibration (Plan 7) — Design

**Date:** 2026-08-05
**Status:** approved design, ready for implementation plan
**Predecessor:** Plan 6 (hardware backend), validated in-game — tag `hw-validated`.

## 1. Purpose

The FCS acts on sensor values whose **sign, axis mapping, and unit** depend on how the
hardware is physically mounted. Guessing any of these wrong produces positive feedback —
the exact failure that killed EasyHover 1 (roll read as pitch; sign flipped). This plan
builds a guided, in-game procedure that **measures** every sign/axis/unit against known
plunger-induced motions and writes them to the hardware config the backend already loads.

Nothing here is hand-assumed. Every sign is measured, or (for pure tape-measure facts)
typed in by the operator. The measured values are aligned to a **fixed convention** that
the mixer already embodies — so mixer, hardware, and sensors all key to the same reference.

## 2. Calibration targets

`vSpeed` is intentionally **not** a target: the level-flight scheme does not consume it
(altitude hold is position-based), and it is derived from `altitude`, so its sign is
automatic. Final list:

| Value | Method |
|-------|--------|
| `gimbalPitchIdx` + `signPitch`, `gimbalRollIdx` + `signRoll` | measured — tilt & hold |
| `gimbalUnit` (scale to rad) | detected — deg vs rad from tilt magnitude |
| `signVelFront`, `signVelRear` | measured — sway (common-mode) + yaw (differential) |
| `signVelMedial` | measured — surge push |
| `signHeading` + `headingScale` (deg→rad) | measured — rotate & hold |
| `signYawRate` | measured — yaw motion (consistency with heading) |
| `heightOffset` | measured — sit on ground, zero altitude |
| `onGroundThreshold` | measured — sit on ground, read optical + margin |
| `yawBaseline` | typed — fore/aft lateral-sensor spacing (blocks) |
| `baroThrusterOffset` | typed — vertical baro→thruster-plane distance (blocks) |

## 3. Canonical sign convention (ground truth)

Derived from the mixer (`fcs/mixer/level_flight.lua`) and the PID negative-feedback
direction (`fcs/schemes/level_flight.lua`). Calibration flips each sensor sign until it
reads **positive** for the named physical motion:

| Sensor | Reads **+** when the craft is… | Basis |
|--------|-------------------------------|-------|
| `pitch` | **nose UP** | +pitch demand lifts front (FL,FR); PID needs +meas for nose-up to correct |
| `roll` | **right wing DOWN** | +roll demand lifts left side (FL,RL); PID needs +meas for right-wing-down |
| `heading` / `yawRate` | **nose rotating RIGHT** (CW from above) | mutually consistent pair; kd damping must not be positive feedback |
| `swayVel` → `swayPos` | **moving RIGHT** | pos integrated from vel → auto-consistent |
| `surgeVel` → `surgePos` | **moving FORWARD** | mixer MAIN pushes forward = +surge |
| `altitude` | **higher** | `getHeight` increases upward; offsets only shift origin |

**Convention rule (now and for every future re-cal):** always induce the plunger motion in
the *convention-positive* direction the prompt names. Correctness comes from mixer,
hardware, and sensors all keying to this same convention — not from the plunger "mimicking"
the thrusters.

### Loop-closure status

- **Fully closed by this cal** (given correct thruster binding, which is accepted as fact):
  heave, pitch, roll, surge. Their thruster directions are already confirmed in-game
  (lift corners lift the right corner; MAIN pushes forward).
- **Closed under the thruster-orientation axiom, with a first-flight insurance note:**
  yaw, sway. These fire the *lateral* thrusters, whose sideways push-direction is asserted
  (careful manual build) rather than eyeball-confirmed. Sensor cal makes heading↔yawRate and
  swayVel↔swayPos mutually consistent and aligned to convention. **First-flight note:** ramp
  yaw/sway authority up from low on the maiden hover as cheap insurance on that one link.

## 4. Inference core — `fcs/io/calibration.lua` (pure, headless-tested)

A **snapshot** is one `backend:sensors()` read plus the raw gimbal `getAngles()` array. The
core is stateless functions over snapshots. Robustness against impure plunger motions is
built in — the operator produces a *dominant* motion in the asked-for axis, never a
surgically pure one.

### Robustness rules

1. **Dominant-channel selection.** Multi-channel steps (gimbal) diff every candidate channel
   and pick the largest-magnitude delta as the axis; sign and unit come from it. A pitch that
   bleeds a little roll still resolves to pitch.
2. **Dominance-ratio confidence gate.** A result is committed only if the dominant channel
   beats the runner-up by a margin (default ≥3×) **and** clears a noise floor. Otherwise the
   step reports *why* (`too-ambiguous` / `too-small`) and asks for a cleaner, bigger motion —
   it never guesses.
3. **Projection decoupling for the lateral pair.** `yawRate = front − rear` (differential)
   and `swayVel = front + rear` (common-mode) are orthogonal. The yaw step reads the
   differential (cancels accidental sway); the sway step reads the common-mode (cancels
   accidental yaw). A dirty plunger yaw-that-also-sways still yields a clean yaw sign.
4. **Peak vs steady capture.** Held poses (attitude/heading/altitude/ground) read
   steady-state, averaging a few samples to kill jitter. Velocities (sway/surge/yaw) are
   transient — capture the **peak** |delta| across the motion window.

### Functions

- `classifyGimbalAxis(neutral, moved) -> {idx, sign, unit, dominant, runnerUp}`
  Diffs both raw gimbal channels; dominant channel = axis; `sign` from its direction;
  `unit = "deg"` if |Δ| exceeds a magnitude threshold (deg and rad are ~57× apart), else
  `"rad"`.
- `classifyScalarSign(neutralVal, sampleVal) -> {sign, magnitude}` — for velMedial, heading.
- `classifyLateralPair(neutral, swaySample, yawSample) -> {signFront, signRear, swayOk, yawOk}`
  Solves the two per-sensor signs from the common-mode (sway sample) and differential (yaw
  sample) projections; reports whether each projection was dominant enough.
- `detectHeadingScale(peakDelta) -> {scale, unit}` — `π/180` if the rotation delta reads in
  the tens (degrees) else `1` (already radians); also yields `signHeading`.
- `computeHeightOffset(groundRawAlt, baroThrusterOffset) -> heightOffset`
  Sets rest-altitude to 0: `-(groundRawAlt + baroThrusterOffset)`.
- `computeGroundThreshold(opticalOnGround, margin) -> threshold`.
- `gate(dominant, runnerUp, floor, ratio) -> "ok" | "too-ambiguous" | "too-small"`.

Purity means the headless suite feeds synthetic snapshots directly, with no CC runtime.

## 5. Procedure — `tools/calibrate.lua` (thin in-game UI, not headless-tested)

Menu of independent, re-runnable steps plus a `run all` that walks them in order:

```
== EH2 CALIBRATE ==
1 attitude    (pitch, then roll — tilt & HOLD)
2 lateral     (sway push, then yaw motion — captures peak)
3 surge       (shove forward — captures peak)
4 heading     (rotate nose-right & HOLD)
5 ground      (sit craft on ground — zeroes altitude, sets on-ground)
6 constants   (type yawBaseline + baroThrusterOffset)
7 verify thrusters (optional: fire each role, watch the corner/side)
8 save & review    (show full binding table, atomic write)
```

Each measured step:

1. **Capture neutral** — read a snapshot at rest.
2. **Prompt the exact convention-positive motion** (e.g. *"Tilt the NOSE UP and hold, then
   press Enter"*).
3. **Sample** — HOLD steps average steady samples; MOTION steps capture peak |Δ| over a
   ~3 s window.
4. **Classify** via the core; **show result + confidence**
   (`pitch → idx 2, sign -1, unit rad  ✓ (0.41 vs 0.03)`).
5. **Confirm before writing.** Gate rejections explain why and offer a redo. Nothing touches
   the config file until confirmed.

`8 save & review` prints the entire resulting binding table for eyeball review, then does a
single atomic write to `/eh2_hw_config.tbl`.

Step 7 (verify thrusters) is optional and not a gate: fires each role briefly so the operator
can confirm the intended corner/side responds. Included because it is nearly free and useful
in the future test-stand era; thruster-role correctness is otherwise accepted as fact.

## 6. Persistence, backend wiring, delivery, testing

### Persistence
Same `/eh2_hw_config.tbl` the backend already loads; `hwconfig.merge` remains additive so new
bindings slot in without disturbing existing ones. New `bindings` keys: `gimbalPitchIdx`,
`gimbalRollIdx`, `signPitch`, `signRoll`, `signVelFront`, `signVelRear`, `signVelMedial`,
`signHeading`, `signYawRate`, `gimbalUnit` (scale), `headingScale`, `yawBaseline`,
`heightOffset`, `onGroundThreshold`, `baroThrusterOffset`. `hwconfig.defaults()` gains
sensible defaults (identity signs, unit=rad scale 1, offsets 0, baseline 1).

### Backend wiring (`fcs/io/backend.lua`)
Surgical additions to `sensors()`:

- `heading = signHeading * headingScale * rawHeading`.
- `yawRate` numerator uses `signYawRate` consistently with the front/rear signs.
- `pitch/roll` multiply by `gimbalUnit` scale in addition to the existing sign/index.
- `altitude = rawBaro + baroThrusterOffset + heightOffset`.

`baroThrusterOffset` is stored and applied as its own explicit term (not silently merged into
`heightOffset`), so the review screen shows build geometry separately and future designs that
skip ground-zero or want absolute lift-plane altitude have the value. On a ground-zeroed craft
its dynamic effect is ~nil (the ground step's trim absorbs a constant vertical offset) — kept
for correctness and portability.

### Delivery
Add `tools/calibrate.lua` and `fcs/io/calibration.lua` to `install_probe.lua`'s fetch list and
write a `/calibrate` launcher with the same `package.path` fix. One `wget run` installs probe
and calibrate together.

### Testing
Headless suite for `calibration.lua`:

- clean motions → correct axis/sign/unit;
- contaminated motions (pitch with ~25% roll bleed; yaw with ~40% sway bleed) → dominant axis
  still wins;
- mushy motions → gate returns `too-ambiguous` / `too-small`, no commit;
- unit detection deg vs rad;
- lateral common/differential solve for both per-sensor signs;
- offset/threshold math.

Backend tests updated so the new sign/scale/offset bindings are applied correctly (heading
scaling, gimbal unit scaling, `baroThrusterOffset` term, yaw-rate sign).

## 7. Out of scope / future work

- **Horizontal baro lever-arm compensation.** A barometer mounted off the lift centroid reads
  a height change when the craft pitches/rolls (moment arm grows with distance). On this craft
  the baro is centered fore/aft and on the left/right center axis, so the effect is negligible.
  A live-attitude compensation term is genuine future work and will be needed for designs with
  an off-center baro.
- **Absolute-altitude / no-ground-zero mode** using `baroThrusterOffset` directly.
- **Test-stand-driven re-cal** — the future 6-DOF Create stand lets each step run with cleaner,
  more repeatable motions; the independent-step menu already supports this.
- **Mixer yaw/sway polarity confirmation** at first flight (low authority ramp), per §3.
