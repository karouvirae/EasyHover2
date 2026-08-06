# EasyHover 2 — Pilot Control + Comms + Cockpit UI (design)

**Date:** 2026-08-06
**Status:** design, awaiting review
**Builds on:** stable-hover (main) — flight-proven flat hover on all axes.

## 1. Overview & scope

Take the craft from a static bring-up harness (`tools/hover_test.lua`) to **pilot-flyable with a cockpit UI**. Three tightly-coupled sub-projects, built as one row, all headless-green; the pilot flies the first in-game integration test **after C is done** (no in-game checkpoints between).

- **A — pilot input** (FCS-local): typewriter → setpoints.
- **B — comms**: inter-PC telemetry + command streams.
- **C — cockpit**: UI-PC role + Basalt-full flight panels.

**In scope:** FLAT flight (attitude auto-leveled) — yaw, lateral (sway), surge (forward = main thrust), lift; engage/disengage, GND safety, position-hold, fuel-pump, DAMPED-clear; a cockpit that reflects reported state and sends commands.

**Explicitly OUT (deferred):** manual pitch/roll tilt & the "pitchable" scheme; flight-mode *content* (only a scaffold panel); NAV/GPS world-frame + autopilot; monitor-touch as a flight-control surface; the install Suite; profiling spans (no-op stub).

## 2. Architecture

### 2.1 FCS runtime (the backbone — new persistent program)
A new flight program on the FCS PC replaces `hover_test` as the thing that actually runs the craft (hover_test stays, for automated tuning regression). Structure per the comms design: **parallel tasks over a single-writer shared snapshot**.

Tasks:
1. **Control** — the rate-adaptive loop (`fcs/runtime/loop.lua`, unchanged) at max rate: reads current setpoints (from the pilot-input module) + sensors, cycles the loop, drives the level actuator (concurrent writes), and writes the latest state into the shared snapshot. Owner/single-writer of actuation + snapshot.
2. **Input (A)** — polls the typewriter, updates a held-key set the control task reads.
3. **Telemetry (B)** — publishes the snapshot as a latest-wins state stream, fire-and-forget, at a **fixed cadence decoupled from the control loop** (v1's lag came from telemetry produced *by* the slow control cycle — never repeat that).
4. **Command (B)** — receives command events, acks, applies via handlers.
5. **Health (B)** — heartbeat out.

The FCS **flies alone if UI/NAV drop** (control + pilot input are local; comms is additive).

### 2.2 Runtime state machine
- **DISENGAGED** (default at boot): loop disarmed → all thrusters 0. Safe; the craft cannot fire.
- **GND-SAFE gate**: `gndSafety` defaults **ON** at boot; an `engage` command is honored only when `gndSafety == OFF`. Deliberate two-step (safety off, then engage) so it can't arm by accident.
- **ENGAGED**: loop armed → holds setpoints, applies pilot input, flies.
- **POSITION-HOLD** (modifier on ENGAGED): pilot input ignored, setpoints frozen at current values, leash lead zeroed → hard station-keep until released.
- **DAMPED** (existing safety): oscillation detector → auto-damp; `clearDamped` recovers.

Engage/disengage = the **existing `Loop:arm(bool)`** (no control-law change): disarmed forces thrusters to 0 and resets the scheme; armed flies. Everything above is runtime-level state gating, not core-math changes.

## 3. Command & telemetry contract (shared by A/B/C)

**Commands** (UI→FCS, event stream, ack+retry, idempotent handlers):
`engage`, `disengage`, `gndSafety{on|off}`, `positionHold{on|off}`, `fuelPump{on|off}`, `clearDamped`, `flightMode{id}` (stub — accepts, stores, no behavior yet).

**Telemetry** (FCS→UI, latest-wins state, fire-and-forget):
attitude (pitch, roll, heading), rates (vSpeed, yawRate, sway/surge vel), positions (alt, sway/surge pos), setpoints (sp_alt, sp_heading, sp_sway, sp_surge), `onGround`, `mode` (DISENGAGED/GROUND/NORMAL/POSHOLD/DAMPED), flags (engaged, gndSafety, positionHold), `loopHz`, fuel (main tank + per-thruster mB / capacity via thruster `getFuelAmountMb`/`getFuelCapacityMb`), `thrustKN` readback, optional per-thruster levels.

**Reported-state only:** the cockpit renders telemetry, never what it merely requested ([[feedback-no-optimistic-ui]]). A pressed ENGAGE button shows engaged only when telemetry says `engaged=true`.

## 4. Sub-project A — pilot input

- **`fcs/input/pilot.lua`** (pure, headless-tested): owns setpoint state `{altitude, heading, swayPos, surgePos}`.
  - `:reset(meas)` — seed setpoints to current craft state (called on engage, so it holds where it is).
  - `:update(dt, held, meas) -> setpoints`:
    - **Yaw**: `heading += yawRate * dt * (held.yawRight - held.yawLeft)`, angle-wrapped.
    - **Lift**: `altitude += climbRate * dt * (held.up - held.down)`, leashed to `meas.alt ± leadCapVert` so it can't run away.
    - **Sway / Surge**: `leash.step` toward `pos ± maxLead` per held direction (fwd = main thrust), speed = cruise ramp — craft-frame.
    - **Position-hold**: when active, ignore `held` and return frozen setpoints.
  - All rates per-second (rate-adaptive); values from a config block.
- **`fcs/input/keymap.lua`** (config): keycode → axis/direction. Default WASD = sway/surge, Q/E = yaw, R/F = lift; user-editable (and the keys must be bound on the typewriter's frequency in-game).
- **Runtime input task**: poll `linked_typewriter.getPressedKeyCodes()` (queued key/key_up events are unreliable in-game — poll current held state), map through the keymap → held set. (Verify the typewriter method name from Simulated source at plan time.)
- **Tests**: synthetic held-sets + dt + meas → assert ramp rates, leash cap, heading wrap, position-hold freeze, reset-on-engage.

## 5. Sub-project B — comms

- **Transport**: raw modem on well-known channels (config: telemetry channel, command channel). Modem type on the craft (wireless vs wired/ender) confirmed at plan time.
- **Telemetry**: latest-wins state stream, fire-and-forget, fixed cadence (~5–10 Hz), serialized snapshot. Newer replaces older; no ordering/ack.
- **Commands**: event stream with **ack + retry** — each command carries an id; FCS acks by id; sender retries until ack or timeout. Handlers idempotent (re-applying `engage` is safe).
- **Health**: FCS heartbeat; peers show link up/down.
- **`fcs/comms/{protocol,telemetry,command,health}.lua`**: the framing / latest-wins / ack-retry logic is **pure and headless-tested against a mock modem**; the real modem is a thin IO shim (same split as the sensor backend).
- **Profiling** event-stream: no-op stub (deferred).

## 6. Sub-project C — UI-PC role + cockpit

- **UI-PC program**: comms client — receives telemetry into a local snapshot, renders panels, sends commands. **Basalt-full only** ([[feedback-basalt-full-build]]). Reported-state only.
- **Panels** (flight-useful set):
  - **FCS control** — ENGAGE / DISENGAGE, CLEAR-DAMPED; shows reported `engaged` + `mode`.
  - **GND safety** — ON/OFF (the engage gate).
  - **Position hold** — ON/OFF (in-air station-keep).
  - **Engine** — fuel-pump START/STOP; shows reported pump state.
  - **Fuel gauges** — main tank + per-thruster fuel (mB / capacity) from telemetry.
  - **Flight status** — alt, vSpeed, heading, attitude, loopHz, drift readout.
  - **Flight-mode** — scaffold only (shows "NORMAL", switch stubbed).
  - **Link status** — comms up/down (health).
- Headless test: render one frame with `basalt.update("timer", -1)` against a mock telemetry snapshot; assert command emission via injected comms.

## 7. Testing strategy

- Each sub-project headless-green in isolation (pure input module; pure comms protocol vs mock modem; UI single-frame render vs mock telemetry).
- **Integration harness** (headless): wire the FCS runtime ↔ a mock modem ↔ the UI single-frame, and assert the command→handler→telemetry→panel round-trip — proving the contract end-to-end **before** the craft ever runs it.
- **No in-game test until the whole row is built.** The first post-C flight is a big integration checkpoint (pilot); expect to retune translation (sim-tuned, flight-unvalidated) the same way hover was.

## 8. Non-goals / open items

**Non-goals:** manual tilt; flight-mode content; world-frame/NAV; monitor-touch flight input; install Suite; profiling spans.

**Verify at plan time:** `linked_typewriter` held-key method (Simulated source); thruster fuel-readback methods (getFuelAmountMb/Capacity — seen in Checkpoint #1); craft modem type + channels; whether the UI-PC reaches the FCS over the craft's wired network or needs a wireless/ender modem.
