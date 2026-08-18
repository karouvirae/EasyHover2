# FCS control batch — MAN lateral, nose-down trim authority, snappy yaw

Date: 2026-08-18. Three independent control changes on the EH2 flight computer,
gathered after the heavier-craft upgrade. All TDD'd on pure units (pilot / schemes /
tuning defaults); rate/console glue stays inspection-verified per the existing
untested-scheduled-loop convention.

## Task 1 — MAN gets lateral movement (PRECISION + tilt, drift-relaxed)

**Target feel (user):** "Essentially behave like PRECISION, just with tilt added. While
manually tilting, the FCS must NOT fight the drift; on releasing tilt, hold position
again. Same for lateral movement."

**Current:** `fcs/schemes/manual.lua` discards lateral — `d.sway, d.surge = 0, 0`
(comment: "no horizontal loop: tilt translates freely"). The keymap
(`keymap.forMode("MAN")` → `M.default`) already maps W/S surge, A/D strafe, Q/E yaw,
Space/Shift climb/descend, ↑/↓ pitch (↑ = nose-down, verified), ←/→ roll — exactly the
requested layout, so **no keymap change**.

**Design:** MAN = the calibrated Level horizontal loop (like PRECISION) with
`policy.tilt = true` **plus** a new `policy.relaxTiltDrift = true`. In `pilot.lua`, after
the sway/surge leash, when any tilt key is held reset the position setpoints to the
measured position each tick (`sp.swayPos = meas.swayPos; sp.surgePos = meas.surgePos`) so
the Translate loop sees ~zero error and does not counter the bank-drift. Releasing tilt
stops the reset → the setpoints freeze at the current position → the loop re-holds. This
is the same "reset setpoint to measured while actively commanding" trick the CPL path
already uses (`if sp.surgeActive then sp.surgePos = meas.surgePos`), retriggered by tilt.

`manual.lua` stops zeroing lateral — it now delegates the full Level update (lateral
included). Lateral (WASD) keeps the PRECISION leashed position-hold: hold to move, release
to hold station.

**Tests:** `test_scheme_manual` (MAN sway/surge now equal Level, not 0);
`test_pilot_modes` (tilt-held resets swayPos/surgePos to measured; tilt-released freezes
them / re-holds).

## Task 2 — More nose-down auto-trim (CPL/DCPL)

**Problem:** the craft has no pitch-down surface — nose-down comes only from front-lift-down
/ rear-lift-up differential. Current trim `= trimGain(0.1) × trimDir(−1) × throttle` gives
only ~−0.1 rad (~5.7°) at full throttle, sharing the ±0.4 rad manual-tilt cap. Not enough
to counter high surge acceleration.

**Design (all tunable — dial in flight):**
- `pilot.lua` coupled trim clamp uses a dedicated `trimCap` (falls back to `tiltCap`) so
  auto-trim can command more nose-down than a hand tilt.
- `tuningdefaults` coupledFeel: `trimGain` 0.1 → 0.35 (~20° at full throttle),
  add `trimCap = 0.5` (~28°, under `attLimit` 0.6).
- CPL/DCPL `caps.pitch` 0.4 → 0.5 so the mixer's lift-differential torque isn't the limiter.

Sign convention (verified): negative pitch setpoint = nose down; `trimDir=-1` = nose-down.

**Tests:** `test_pilot_coupled` (trimCap lets nose-down exceed tiltCap when set; existing
tiltCap-fallback test still green); `test_tuning_modes` (CPL/DCPL trimGain/trimCap/caps.pitch
values).

## Task 3 — Snappy, accurate yaw

**Root cause of oversteer:** while Q/E is held the heading setpoint is leashed ~0.70 rad
(~40°) *ahead* of actual (this is what sets the steady turn rate). On release the setpoint
is still 40° ahead, so the craft keeps turning ~40° past the release point before settling.

**Design (rate-command while held → heading-hold on release):** in `pilot.lua`, on the
yaw-key **release edge** (tracked via `self.yawWasHeld`), snap the setpoint to
`angle.wrap(meas.heading + yawStopLead × meas.yawRate)` — capture current heading plus a
small predictive stopping lead so the loop brakes to a crisp halt where you released,
instead of chasing the 40° lead. Edge-triggered so a settled release still fights drift
(the setpoint stays fixed, not re-tracking `meas.heading` every tick). Same fix on the CPL
rudder path. `yawStopLead` is a new feel knob (default ~0.15) — lower = harder stop.

While held, the ramp + `leadCapHeading` leash are unchanged (steady, predictable turn
rate). `kd`/`leadCapHeading` remain the fine-tuning knobs.

**Tests:** `test_pilot` (release captures ~current heading, not the leashed lead;
edge-trigger holds against post-release drift instead of re-capturing).

## Verification
Headless suites (source + dist) green; e2e PASS; rebuild + manifest `--check` IN SYNC.
In-world: MAN flies like PRECISION + tilt with no drift-fight during tilt; CPL/DCPL holds
the nose down harder under throttle; yaw turns while held and stops crisply on release.
On green + good review: merge to main and push (user pre-approved).
