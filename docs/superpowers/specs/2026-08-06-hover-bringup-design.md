# EasyHover 2 — Hover Bring-Up Test — Design

**Date:** 2026-08-06
**Status:** approved design, ready for implementation plan
**Predecessor:** Plan 7 (sensor calibration), merged + validated in-game.

## 1. Purpose

First real-hardware flight of the rebuilt FCS. A self-contained tool that, on a keypress,
flies an automated **climb → hold → land** profile on the actual craft and logs every
control cycle to a file for post-flight analysis. It is the moment-of-truth for the whole
FCS stack (does it hold altitude/attitude/heading/position on real hardware?) and the
measurement vehicle for the empirical unknowns the sim could not answer: real loop rate,
heave-bob amplitude, horizontal drift, and the true `hoverDuty`.

Validation is **in-game, pilot-driven**: the tool is built + headless-tested here; the user
flies it and posts back the log.

## 2. Flight profile

Automated, keypress-triggered, auto-landing. Setpoint altitude moves as a **ramp** (never a
step — a step commands full-tilt bang-bang; a ramp stays controlled and the data stays
readable).

| Phase | Behavior | Default |
|-------|----------|---------|
| **IDLE** | craft sits inert (FCS disarmed, thrusters off); waits for launch keypress | — |
| **CLIMB** | armed; setpoint ramps `baseAlt → baseAlt+climbHeight` | climbHeight 5 blocks @ 1.0 blk/s |
| **HOLD** | setpoint fixed at top; station-keep | 10 s |
| **DESCEND** | setpoint ramps `top → baseAlt` | 0.7 blk/s (softer touchdown) |
| **LANDED** | on `onGround` (or `alt ≤ baseAlt+landEps`), disarm (all thrusters → 0), done | landEps 0.4 |

**Why IDLE is disarmed, not an armed ground-hold:** `hoverDuty` is the duty that balances
weight at hover; commanding it on the ground would lift the craft before the keypress. IDLE
therefore keeps thrusters off; the launch keypress arms the loop and begins CLIMB, whose ramp
starts at `baseAlt` so thrust comes up smoothly into liftoff.

All profile numbers are fields of `fcs/tuning.lua` so they retune in one place between flights.

## 3. Controls (keyboard only — the FCS PC is on the craft, pilot in reach)

- **Space** — launch (IDLE → CLIMB). Ignored after launch.
- **Q** — manual abort: force DESCEND immediately (controlled descent to land). Backup for a
  failed auto-land.
- **Physical fuel-pull** — hard kill; thrust dies, craft settles from ≤5 blocks. Always available.

The tool's loop is event-driven so it ticks the FCS at full rate *and* stays responsive to keys.

## 4. Automatic safety cutoffs (in the profile state machine)

- **Watchdog:** if elapsed time since launch exceeds `watchdog` (default 30 s) and not yet
  landed, force DESCEND.
- **Overshoot guard:** if measured `alt > top + overshootMargin` (default 2 blocks), force DESCEND.
- **Oscillation:** the runner reads `Loop:getMode()`; a `DAMPED` trip calls `profile:abort()`
  → DESCEND. (The Loop already neutralises steering and holds altitude in DAMPED.)

Abort and every safety cutoff route to the same controlled DESCEND → LANDED path, so the craft
always comes down under FCS control if it can; fuel-pull is the fallback if it cannot.

## 5. Architecture — three focused units + the tool

### 5.1 `fcs/tuning.lua` (new — canonical tuning, single source of truth)
Returns a table of the known-good sim gains (currently copy-pasted across
`tests/test_integration.lua`), plus actuator/safety/profile params. Not wired into the
existing tests (out of scope) — it exists so the runner has one authoritative place to read
and retune:

```
gains   = { hoverDuty = 0.66,
            alt   = {kp=0.04, ki=0.02, kd=0.30, tauD=0.2, iMax=0.3, iMin=-0.3},
            pitch = {kp=0.3, ki=0, kd=0.4, tauD=0.2},
            roll  = {kp=0.3, ki=0, kd=0.4, tauD=0.2},
            yaw   = {kp=0.8, ki=0, kd=1.4},
            sway  = {kp=0.5, ki=0, kd=0.5},
            surge = {kp=0.3, ki=0, kd=0.5} }
pwmPeriod = 0.3
caps    = { pitch=0.2, roll=0.2, yaw=0.5, sway=0.5, surge=0.5 }   -- attitude/steering only; heave unclamped
osc     = { window=1.0, minChanges=6 }
dtMax   = 0.5
profile = { climbHeight=5, climbRate=1.0, holdTime=10, descendRate=0.7,
            landEps=0.4, watchdog=30, overshootMargin=2 }
```

**Real-world caveat:** `hoverDuty = 0.66` is the *sim* value. If real thrust-to-weight differs
a lot the altitude integrator (±0.3 authority) may saturate and it won't hold — the log makes
this obvious (`alt` can't reach setpoint, `heave` demand pinned near a rail), and it's a
one-line fix in `tuning.lua`. **The first flight is as much about finding real `hoverDuty` as
flying the profile.**

### 5.2 `fcs/bringup/profile.lua` (new — pure state machine, headless-tested)
No CC dependencies; pure logic over its own state.

- `Profile.new(cfg)` — cfg = the `tuning.profile` table plus `baseAlt`. Sets `top = baseAlt +
  climbHeight`, `phase = "IDLE"`, `target = baseAlt`.
- `Profile:begin()` — IDLE → CLIMB (no-op if already launched).
- `Profile:abort()` — force `phase = "DESCEND"` unless already LANDED.
- `Profile:update(dt, alt, onGround) -> { phase, targetAlt, active, done }`
  - IDLE: `target = baseAlt`, `active = false`.
  - Accumulate elapsed once launched; apply watchdog and overshoot guards (either → DESCEND).
  - CLIMB: `target = min(top, target + climbRate*dt)`; when `target ≥ top` → HOLD (reset hold clock).
  - HOLD: `target = top`; accumulate hold time; when `≥ holdTime` → DESCEND.
  - DESCEND: `target = max(baseAlt, target − descendRate*dt)`; when `onGround` or
    `alt ≤ baseAlt + landEps` → LANDED.
  - LANDED: `active = false`, `done = true`, `target = baseAlt`.
  - `active = phase ∈ {CLIMB, HOLD, DESCEND}` (drives `Loop:arm`).

### 5.3 `fcs/bringup/instrument.lua` (new — pure logging/summary, headless-tested)
- `M.header() -> csv header string` (fixed column order).
- `M.formatRow(sample) -> csv line`.
- `Summary.new()` / `summary:add(sample)` / `summary:finalize() -> metrics` — **incremental**
  accumulators (no row hoarding). Metrics: flight duration; loop Hz min/avg/max; per-phase
  altitude-tracking error (mean & max `|alt − sp_alt|` for CLIMB/HOLD/DESCEND); HOLD-phase bob
  amplitude (`max−min alt` during HOLD); peak climb vSpeed and peak descent vSpeed; max
  `|pitch|` and `|roll|`; horizontal drift (`swayPos` range, `surgePos` range); heading drift
  (`max|heading − heading₀|`); touchdown vSpeed (vSpeed at LANDED transition); whether `DAMPED`
  ever tripped.
- `M.formatSummary(metrics) -> string` — plain `key: value` block (readable unparsed).

A **sample** is a plain table the tool assembles each cycle:
`{ t, dt, hz, phase, mode, sp_alt, alt, vSpeed, pitch, roll, heading, yawRate, swayVel,
surgeVel, swayPos, surgePos, onGround, heave, dPitch, dRoll, dYaw, dSway, dSurge, duties{…} }`.

### 5.4 `fcs/runtime/loop.lua` (modify — two small backward-compatible enhancements)
The runner must read sensors once per tick (the profile needs `alt`/`onGround` to pick the
setpoint *before* the cycle drives thrusters; reading again inside the cycle would double the
~7-peripheral mainThread cost and can halve an already tick-bound loop rate). So:
- `Loop:cycle(dt, m)` — if `m` is provided, use it instead of calling `self.backend:sensors()`
  (`m = m or self.backend:sensors()`). Existing callers pass no `m` and are unaffected.
- `Loop:cycle` returns a diagnostics table `{ mode, m, demands, duties }` (demands/duties present
  when armed; the disarmed early-return returns `{ mode, m, demands=nil, duties=nil }`). Existing
  callers ignore the return.

### 5.5 `tools/hover_test.lua` (new — in-game shell, not headless-tested)
1. Load merged config (`hwconfig`) + `tuning`. Build `backend`, `scheme`, `mixer`,
   `pwm(period=tuning.pwmPeriod)`, `sd`, `Loop{…, caps=tuning.caps, osc=tuning.osc,
   dtMax=tuning.dtMax}`.
2. Capture baseline: average a few `backend:sensors()` reads → `baseAlt`, `heading₀`,
   `swayPos₀`, `surgePos₀`. Fixed setpoints for the flight: `pitch=0, roll=0,
   heading=heading₀, swayPos=swayPos₀, surgePos=surgePos₀`; altitude comes from the profile.
3. `profile = Profile.new(tuning.profile ∪ {baseAlt})`. `summary = Summary.new()`.
   Open the crash-safe row file `/eh2_hover_log.csv.part`, write the CSV header.
4. Event loop: `os.startTimer(0)` cadence. On each timer tick — measure `dt` from `os.epoch`;
   `m = backend:sensors()`; `pr = profile:update(dt, m.altitude, m.onGround)`;
   `loop:setpoints{ altitude=pr.targetAlt, pitch=0, roll=0, heading=heading₀,
   swayPos=swayPos₀, surgePos=surgePos₀ }`; `loop:arm(pr.active)`; `diag = loop:cycle(dt, m)`;
   if `diag.mode == "DAMPED"` then `profile:abort()`; assemble the sample, `summary:add(sample)`,
   append `formatRow` to the part-file; reschedule the timer. On `key` events: Space →
   `profile:begin()`; Q → `profile:abort()`. Exit when `pr.done`.
5. On exit (done, or error via `pcall`): write the final `/eh2_hover_log.csv` =
   `formatSummary(summary:finalize())` + blank line + the CSV (header + streamed rows from the
   part-file). Print the summary to the terminal. Attempt `pastebin put /eh2_hover_log.csv`;
   print the code/URL if the server allows it, else print the file path for manual retrieval.

## 6. Delivery

New installer `tools/install_hovertest.lua` (mirrors `install_probe.lua`): fetches the full
runtime dependency set and writes a `/hovertest` launcher with the `package.path` fix. Deps:
`tools/hover_test.lua`, `fcs/tuning.lua`, `fcs/bringup/profile.lua`, `fcs/bringup/instrument.lua`,
`fcs/runtime/loop.lua`, `fcs/schemes/level_flight.lua`, `fcs/mixer/level_flight.lua`,
`fcs/actuate/pwm.lua`, `fcs/actuate/sigma_delta.lua`, `fcs/control/pid.lua`,
`fcs/control/heading.lua`, `fcs/control/translate.lua`, `fcs/safety/oscillation.lua`,
`fcs/envelope.lua`, `fcs/frame.lua`, `fcs/angle.lua`, `fcs/io/backend.lua`, `fcs/io/shim.lua`,
`fcs/io/hwconfig.lua`.

## 7. Testing

Headless (CraftOS-PC, `bash tests/run_headless.sh`):
- **`test_profile.lua`** — IDLE inactive at baseAlt; begin→CLIMB ramps toward top; reaching top
  → HOLD; holdTime elapsed → DESCEND; descend ramps down; onGround → LANDED/done; abort forces
  DESCEND; watchdog forces DESCEND; overshoot forces DESCEND; `active`/`done` flags correct per
  phase.
- **`test_instrument.lua`** — header/row column contract; Summary over a synthetic flight →
  correct bob amplitude, per-phase tracking error, drift ranges, Hz stats, DAMPED flag,
  touchdown vSpeed.
- **`test_loop.lua`** (extend runtime coverage) — `cycle(dt, m)` uses the provided `m` (verified
  with a sensor-call-counting backend: exactly one read when `m` passed by the caller, i.e. zero
  internal reads); `cycle` returns `{mode, m, demands, duties}` when armed; `cycle(dt)` with no
  `m` still reads internally (backward compat).
- Register all new suites in `tests/run_headless.sh`.

The `tools/hover_test.lua` shell is in-game-validated by the pilot (the deliverable is the log).

## 8. Out of scope / future

- Auto-driving the fuel relay (manual fuel this flight; disarm cuts thrust via `setPower(0)`).
- Pilot setpoint control / typewriter input (Plan 11).
- Refactoring existing tests onto `fcs/tuning.lua`.
- Any comms/telemetry to another PC (Plan 8) — this tool is fully FCS-PC-local.
