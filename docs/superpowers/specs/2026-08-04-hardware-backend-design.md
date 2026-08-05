# EasyHover 2 — Hardware Backend + Bring-up Probe (Plan 6 design)

**Status:** design, approved in brainstorming. First plan of the "make it fly in-game" phase.

**Purpose:** give the merged FCS a **real backend** that drives Create: Simulated/Propulsion peripherals through the exact interface the simulator uses (so the whole FCS drops onto it unchanged), plus a **standalone bring-up probe** to bind hardware, confirm the peripheral APIs against reality, and measure real timing — all **before any flight**.

**Why first (the reorder):** everything through Plan 5 was proven headless against a synthetic plant. The real peripheral type-strings, `mainThread` cost, achievable loop rate, sensor units, and sign conventions are still assumptions from source-reading. Validating them in-game *now* de-risks the entire UI/comms/Suite build that follows.

---

## 1. The backend

The seam between the FCS and Minecraft. Same interface as the sim — `backend:sensors()`, `backend:setThruster(id,on)`, `backend:liftIds()/lateralIds()/mainIds()/frontalIds()` — so the FCS is a drop-in. Two parts:

- **Peripheral shim** — thin wrapper over `peripheral.wrap/getNames/getType` and the actual mod method calls. The only part not unit-testable.
- **Backend logic** — pure, mock-tested: config→peripheral binding, sensor assembly, thruster driving, `onGround`.

**Actuation:** `setThruster(id, on)` → the bound thruster peripheral's `setThrust(15)` (on) / `setThrust(0)` (off). Full-on/off bang-bang — exactly what the PWM and sigma-delta modulators emit. Thruster ids: `FL FR RL RR` (lift), `YFL YFR YRL YRR` (lateral), `MAIN`, `FRL FRR` (frontal).

**Sensor assembly** (`sensors()` returns the control-critical set):
- `altitude` — barometer `getHeight()` + configured **height-offset** (thrusters aren't at sensor height).
- `vSpeed` — **derived: filtered Δaltitude / dt** from the barometer (no vertical-velocity sensor exists; the barometer is accurate). Same signal the altitude PID differentiates internally, now exposed.
- `pitch`, `roll` — gimbal `getAngles()` (axis order + sign from the bindings table).
- `heading` — nav table `getRelativeAngle()`.
- `yawRate` — `(velFront − velRear) / baseline` from the two lateral velocity sensors; `swayVel` — their average; `surgeVel` — the medial velocity sensor. (Signs from bindings.)
- `swayPos`, `surgePos` — integrated velocity (drifts slowly; GPS makes it absolute later).
- `onGround` — down-optical `getDistance()` < configured threshold.
- `pitchRate`/`rollRate` — telemetry-only, derivable if wanted; **not control-critical** (the attitude PIDs differentiate their own measurement).

**Sign bindings default to identity** in this plan (raw reads pass through). The sensor-calibration procedure (Plan 7) measures and fills them; until then the backend is a faithful raw pass-through.

**Resilience:** re-scan peripherals after assembly/reboot (contraptions reboot across assembly); treat a missing peripheral as a recoverable, annunciated state, not a crash.

---

## 2. The bring-up probe

A **standalone** program run on the FCS PC before any flight (reuses the backend's peripheral shim). **Plain terminal/monitor UI** — no Basalt. Five functions:

1. **Discover** — list every `peripheral.getNames()` with its `getType()` (learns the real type-strings — a top unknown).
2. **Bind** — a minimal menu to assign each discovered peripheral → role/position (the 11 thruster ids + the 7 sensor roles + fuel relay), written to the shared config. (The pilot reads each id by reconnecting one thruster's modem at a time — the probe does **not** auto-identify.)
3. **Sensor readout** — live raw values of each bound sensor (real numbers + units; confirms they work).
4. **Thruster toggle** — manually flip a bound thruster on/off + read back `getCurrentThrustKN` (pilot keeps the craft grounded/secured — their call).
5. **Timing** — a timed burst of `setThrust` calls → real `mainThread` cost per write + achievable Hz; plus a real FCS-cycle-rate measurement over M cycles.

**Checkpoint #1:** the pilot runs the probe in-game and reports the type-strings, sensor values/units, thrust readback, and timing numbers. We reconcile against this design before Plan 7.

---

## 3. Config, testing, scope

**Config** — one additive Lua table (per §15 additive-config): `thrusters = {FL=..,…}`, `sensors = {altimeter, gimbal, velFront, velRear, velMedial, navTable, downOptical}`, `fuelRelay`, `bindings = {signs, gimbal axis-order, heightOffset, onGroundThreshold, yawBaseline, vSpeedFilterTau}`. The probe writes it; the backend reads it (defaults merged under saved values).

**Testing** — the backend **logic** is unit-tested headless against a **mock peripheral table** (scripted fake peripherals): proves velocity fusion (yawRate/sway/surge), the vSpeed derivation, sign application, thruster mapping, `onGround`, and that it satisfies the same interface the sim does (drop-in). The peripheral shim + probe UI are thin and verified **in-game by the pilot**.

**Out of scope (later plans):** the calibration procedure that measures the sign bindings (Plan 7); the polished Basalt config UI (Plan 10); actual flight / hover (Plan 13); comms/telemetry (Plan 8).

---

## Hardware-vs-sim reconciliation (the honest deltas)

- `vSpeed`, `pitchRate`, `rollRate` were *handed over* by the sim; real hardware **derives** them (vSpeed from barometer Δ; rates only if needed for telemetry). Control is unaffected — the loops differentiate their own measurement.
- Peripheral **type-strings, units, and `mainThread` cost** are unknowns the probe resolves; the backend must not hardcode a type-string it hasn't confirmed (bind by peripheral **name** from config, not by guessed type).
- **Signs** are identity until calibration — so the first in-game readouts are raw and may read "backwards" on some axes; that's expected and is exactly what Plan 7 fixes.
