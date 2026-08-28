# FCS mode expansion: LDG + DRN — design

**Date:** 2026-08-28
**Status:** approved (brainstorm), pending spec review
**Scope:** two new selectable flight modes — **LDG** (landing) and **DRN** (drone) —
plus the shared mode-registry/parked plumbing they need. **TRK is explicitly deferred**
(see Deferred). PR #10 (§11.7 ground-zero-integrators) is unrelated and stays parked.

---

## 1. Summary

Add two flight modes and rework the ground/parking model so it is owned by exactly one
mode:

- **LDG** — the boot-default mode. A stabilized, position-holding scheme (PRECISION-like)
  with **drastically reduced thruster caps** (especially the main/surge thruster) for
  precise, gentle liftoff and landing. LDG is the **only** mode that reads the down
  optical sensor and the **only** mode that can put the craft into the parked state, using
  a *permissive* landed-detector that tolerates slightly tilted / uneven ground.
- **DRN** — a drone-style **tilt-to-fly** mode: a pure attitude + altitude controller with
  **no translate loop**. The pilot (or, later, the A/P) moves the craft purely by tilting
  the body via pitch/roll and slewing heading via yaw; releasing the sticks auto-levels to
  a stationary hover.

The parked state becomes a **global latch**: only LDG can set it, every mode honors it
(zero control, ascend-only), and any mode clears it by ascending.

---

## 2. Background — current behavior (established from the code, 2026-08-28)

Verified by reading source + git archaeology; recorded here so the plan starts from fact:

- **`onGround`** (`fcs/io/backend.lua`) has been computed identically since `d9db6c9`:
  `optD = downOptical:getDistance(); onGround = optD ~= nil and optD < onGroundThreshold(~1.5)`.
  It is read **every tick, in every mode**, and has never been removed or changed.
- **`Flight:_parked`** (`fcs/runtime/flight.lua`, introduced `5ffe2f3` 2026-08-09) requires
  `onGround` **and** at-rest (`|vSpeed|,|swayVel|,|surgeVel| < moveEps=0.5`) **and** no
  climb-hold. The at-rest velocity gate is the "don't land while flying low over trees"
  guard and has been present since the predicate was born. `f2c405f` (2026-08-20) added a
  single guard: not-during-autopilot. Nothing else changed it.
- Parking does **not** disengage: it keeps `engaged=true` and `loop:arm(false)` (zero
  thrust, held), and `held.up` un-parks instantly.
- **`onGround` has a second effect:** in `Loop:cycle` the `grounded` flag is passed as the
  scheme's `freeze` argument (on-ground integrator anti-windup). Gating ground-sensing at
  the source therefore also removes this freeze in non-LDG modes — acceptable, because
  those modes are airborne-only once LDG has done the liftoff.
- **Modes** are built once at boot in `fcs/modes/registry.lua` from `SPECS` entries
  `{ id, label, ctor(scheme), policy }`, combined with `tuning.forMode(id)` →
  `{ gains, caps, feel }`. Selection is an O(1) `Loop:setActive(d)` + `Pilot:setMode(policy,feel)`.
  Per-mode caps live in `fcs/io/tuningdefaults.lua` as `DEFAULTS.modes.<ID>`.
- **Keymap** (`fcs/input/keymap.lua`): `M.forMode(id)` returns `M.coupled` for CPL/DCPL,
  else `M.default`.
- **UI mode chips** (`ui/basalt/regions/fcs.lua`): real chips call
  `M._onMode(runtime, id)` and register in `modeCtrls[id]`; the radio coloring iterates
  `FcsPanel.MODES`. `DRN/NOL/TRK` are currently inert red placeholders.

---

## 3. Shared plumbing changes

### 3.1 Mode descriptor behavior flags
Extend each mode descriptor (and its `SPECS` entry) with two declarative flags, both
defaulting **false**:

- `groundSense` — this mode reads the down optical sensor (→ `onGround`, `groundDist`).
- `canPark` — this mode's landed-detector may **set** the parked latch.

Only **LDG** sets both true. All other modes leave them false.

### 3.2 Ground-sensing gated at the source
The backend stops reading `downOptical` unconditionally. Add `Backend:setGroundSense(bool)`:

- **enabled** (LDG): read `downOptical:getDistance()`, publish `onGround` (as today) **and**
  the raw `groundDist = optD` in `meas`.
- **disabled** (all other modes): skip the optical read entirely; `onGround = false`,
  `groundDist = nil`.

`Flight` calls `backend:setGroundSense(d.groundSense)` on every mode switch (and at boot
for the default mode). This delivers both goals at once: only LDG pays the per-tick
peripheral read (the contended mainThread read flagged in the sensor-snapshot note), and
`onGround`/`_parked` are inert in non-LDG modes.

`Flight` therefore needs a backend handle (or an injected `setGroundSense` callback) —
inject `deps.setGroundSense`. (Loop already owns the backend; wiring passes the same
setter.)

### 3.3 Parked becomes a global latch
Replace the per-tick recompute with a latched `self.parked` and three owned transitions:

- **SET** — only when `flightMode == "LDG"`, engaged, and the LDG landed-detector
  (§4.3) is satisfied.
- **HONORED** — in **every** mode, while `parked`: `loop:arm(false)`, `pilot:reset(meas)`,
  all pilot inputs ignored **except** ascend. (Zero control; craft held.)
- **CLEARED** — in **every** mode: `held.up` (ascend) drops the latch on that tick; the
  current mode's FCS then arms and takes over.

`parked` is a sub-state of `engaged`; a full disengage (master off) clears it. Autopilot
active clears/blocks it (as today). Telemetry keeps publishing `parked` and mode `"PARKED"`.

Sketch (`Flight:step`, engaged branch):
```
if self.parked then
  if held and held.up then
    self.parked = false            -- ascend un-parks (any mode) -> fall through to control
  else
    self.pilot:reset(meas); self.loop:arm(false)   -- honored everywhere
    -- (skip normal control this tick)
  end
end
if not self.parked then
  if self.canParkActive() and self:_ldgLanded(held, meas) then   -- SET: LDG only
    self.parked = true; self.pilot:reset(meas); self.loop:arm(false)
  else
    -- normal control (pilot/comAuto -> setpoints -> arm(true))
  end
end
```
(`canParkActive()` = the active descriptor's `canPark`.)

### 3.4 Registry + keymap + UI
- `SPECS` gains `LDG` and `DRN` entries (§4, §5). `registry.default = "LDG"`.
- `keymap.forMode`: `DRN → M.drone` (new layout), `LDG → M.default`, CPL/DCPL unchanged.
- UI: promote two placeholders to real chips — rename `NOL`→`LDG`, activate `DRN`
  (onClick `M._onMode`, `modeCtrls` entry, add to `FcsPanel.MODES` + `MODE_LABEL`).
  `TRK` stays an inert placeholder.

---

## 4. LDG mode

- **Scheme:** reuse `Level` (PRECISION's stabilized position-hold scheme) — full sway/surge
  position hold so the craft doesn't drift while descending.
- **Policy:** `{ tilt = false, surge = "position" }` (PRECISION-like). **Keymap:** `M.default`.
- **Flags:** `groundSense = true`, `canPark = true`.
- **Caps (`DEFAULTS.modes.LDG`):** sharply reduced **surge** (main) and **sway** so the
  craft cannot accelerate hard (especially forward); pitch/roll/yaw kept large enough to
  steer. Reduced caps apply the **whole time LDG is active** (it is the gentle takeoff/
  landing mode). Starting numbers are placeholders, tuned in-world.

### 4.3 LDG landed-detector (`_ldgLanded`) — permissive, for uneven ground
Sets the parked latch when **all** hold. The bands are *tolerant* (they enable landing on
tilted/uneven ground within limits), not stricter:

- **Grounded:** `groundDist ~= nil and groundDist <= groundClear` — an **at-or-below
  threshold** (bumps and edges read smaller and still count).
- **Stable:** `|vSpeed|, |swayVel|, |surgeVel| < parkDriftEps` — very small; only "VERY
  slight" residual drift permitted.
- **Rested attitude:** `|pitch| <= parkTiltBand and |roll| <= parkTiltBand` — a tolerance
  so a craft settled on a slope still parks (future hydraulic legs dampen the rest).
- **Hands-off:** no active tilt input (`pitchUp/pitchDown/rollLeft/rollRight` not held) and
  no climb-hold (`held.up`).

**New config block** `park = { groundClear, parkDriftEps, parkTiltBand }` (placeholder
defaults, tuned in-world). `groundClear` replaces the ad-hoc `onGroundThreshold` role for
LDG's purposes; `onGround` itself keeps its existing meaning for the loop's freeze.

### 4.4 Boot default
`registry.default = "LDG"`. Every boot starts in LDG (and `setGroundSense(true)`). No mode
persistence across reboots. (CPL as an alternate boot default is future master-mode work.)

---

## 5. DRN mode — tilt-to-fly

- **Scheme:** new `fcs/schemes/drone.lua` — attitude (pitch/roll from pilot setpoints) +
  heading-hold + altitude-hold, with **no translate loop**: sway/surge demands forced to 0,
  so the dedicated lateral and main effectors are unused. The craft translates only because
  a commanded body tilt vectors the lift thrust (nose-down → drift forward), like a
  multirotor. Reuses `Level`'s attitude/heading/alt PIDs; strips the sway/surge position
  loop.
- **Policy:** `tilt = true` with a new `translate = false` marker so `Pilot:update` skips
  the sway/surge leash for this mode (the generic leash currently always runs). Pitch/roll
  auto-level toward 0 on release (existing `toward()` ramp) → returns to a stationary hover.
- **Keymap (new `M.drone`):** `W/S → pitch`, `A/D → roll`, `Q/E → yaw`,
  `R/F (+Space/LShift) → lift`. Arrows unused (or reserved for fine-tune later).
- **Flags:** `groundSense = false`, `canPark = false` — DRN never parks and never reads the
  ground sensor.
- **Caps (`DEFAULTS.modes.DRN`):** generous pitch/roll authority (so the craft is agile and
  tilts responsively), normal yaw/alt; sway/surge caps irrelevant (demands are 0).

---

## 6. Testing strategy (TDD)

All pure/host-testable via CraftOS-PC headless suite; mod peripherals mocked.

- **Backend ground-sense gate:** with sensing off, `downOptical` is not read and
  `onGround=false`/`groundDist=nil`; with sensing on, both are published.
- **Parked latch state machine:** SET only in LDG when `_ldgLanded` true; SET refused in
  non-LDG even when the craft is grounded+still; HONORED (arm false, inputs ignored) after
  a mode switch away from LDG; CLEARED by ascend in an arbitrary mode; disengage clears.
- **`_ldgLanded` bands:** parks on a tilted-but-within-band, at-rest, at-clearance craft;
  refuses when tilt exceeds band, when drifting, when a tilt key is held, when above
  `groundClear`.
- **LDG caps:** reduced surge/sway present in the descriptor; envelope clamps to them.
- **DRN scheme:** sway/surge demands are exactly 0 regardless of measured position error;
  pitch/roll track the setpoint; release auto-levels toward 0.
- **Keymap `forMode`:** DRN→drone, LDG→default, CPL/DCPL→coupled unchanged; drone layout
  maps WASD→pitch/roll etc.
- **Registry/boot:** `registry.default == "LDG"`; LDG/DRN descriptors carry the right flags;
  boot enables ground-sense.
- **UI:** LDG/DRN chips are real (onClick emits the mode command), radio coloring includes
  them, `NOL` gone, `TRK` still inert. Cover `regions/fcs.lua` apply + `_onMode`.

Regenerate `dist/` + manifests; full headless (`tests/run_headless.sh`) and dist suite
must stay green.

---

## 7. Deferred / out of scope

- **TRK (trick mode)** — deliberately deferred. A full 360° maneuver needs an **open-loop
  maneuver executor** (fixed-demand rotation + cumulative-angle completion + arrest/
  stabilize, with tap/hold-repeat/release semantics). That same executor is a dependency of
  the **autopilot**. Building it twice would create two divergent maneuver engines — a
  no-no. TRK stays an inert placeholder chip; **the A/P's executor will drive TRK later** as
  the single source of truth. Its design (reserved keys I/J/K/L/U/O, 6 tricks, safety gates)
  is captured in the brainstorm for when A/P lands.
- **CPL/DCPL as selectable master modes / alternate boot default** — future.
- **PR #10** (§11.7 ground-zero-integrators) — unrelated; parked pending a later batch.
- **Hydraulic landing legs** — future hardware the permissive LDG bands are designed to
  serve; not part of this software work.

---

## 8. Open tuning items (in-world, not blocking)

- LDG caps magnitudes (surge/sway reduction factor).
- `park.groundClear`, `park.parkDriftEps`, `park.parkTiltBand` values (tilt band tied to
  the eventual landing-leg travel).
- DRN pitch/roll caps and tilt feel (rate/cap).
