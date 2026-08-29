# EasyHover 2 — Flight-mode / Master-mode split

**Date:** 2026-08-29
**Status:** approved (chat)
**Scope:** Split the single 7-entry mode selector into two independent selectors — **flight modes** (control scheme / effectors / keymap) and **master modes** (horizontal drift law). Fix DRN and forward-trim to their intended behavior in the process. Excludes trim *effectiveness* tuning (deferred) and autopilot.

## 1. Goal

Today a mode is one monolithic descriptor bundling scheme + mixer + caps + feel + policy, selected one-at-a-time from a 7-item list. CPL/DCPL are two of those seven, and they fuse two unrelated concerns: a horizontal drift law (arrest vs. coast) *and* a bespoke "plane" control scheme (rudder-only yaw, cushioned brake, throttle detent, strafe).

Separate the two concerns:

- **Flight mode** — *how the pilot commands the craft*: which thrusters the pilot drives, tilt vs. translate, and the keymap. Five modes: PRECISION, MAN, CRUISE, LDG, DRN.
- **Master mode** — *what the FCS does with horizontal momentum when the pilot is hands-off*: CPL (arrest drift / hold station) or DCPL (coast). Two modes, always exactly one active.

The two are orthogonal and coexist: exactly one flight mode **and** exactly one master mode are active at all times. They never set the same thing, so they cannot interfere.

## 2. What each layer owns

**Flight mode owns:**
- The scheme (`Level` / `Manual` / `Cruise` / `Drone`).
- The keymap (`M.default` for PRECISION/MAN/CRUISE/LDG, `M.drone` for DRN).
- The per-mode caps and feel.
- The translation policy: `tilt` (pilot commands pitch/roll), `translate` (pilot directly drives the horizontal thrusters), landing (`groundSense`/`canPark`, LDG only).

**Master mode owns:**
- The hands-off horizontal drift law (§4).
- The gate for forward trim (§5) — trim is a master-mode capability, present and identical in both CPL and DCPL.
- (Rampable climb, §7, is common to both master modes and — since a master mode is always active — is simply always on.)

Altitude hold, pitch/roll (attitude) hold, and heading/yaw hold are **always** active in every combination. DCPL does **not** free-spin yaw; only lateral/fore-aft translation is left to coast.

## 3. Deletions

- **`fcs/schemes/coupled.lua` and `fcs/schemes/decoupled.lua`** — removed. Their drift law becomes the master-mode rule (§4); their yaw-rerouting/brake/strafe/throttle behavior is dropped outright.
- **`M.coupled` keymap** (`fcs/input/keymap.lua`) — removed, along with the `rudder`, `finesurge` flag plumbing and the coupled input block in `pilot.lua` (throttle ramp, cushioned brake, strafe, rear-only rudder, full-yaw comma/period). Keymaps come only from flight modes.
- CPL/DCPL leave the flight-mode registry SPECS list.

## 4. Master mode — the unified horizontal-hold rule

Key observation: MAN's `relaxTiltDrift` and the old `decoupled` idle-zeroing are the *same* operation — snap the horizontal position setpoint to the measured position so the translate loop produces zero corrective force. They differ only in *when* they fire. Unify them into one per-axis rule, evaluated independently for surge and sway:

| Pilot state (this tick, this axis) | CPL | DCPL |
|---|---|---|
| directly translating (flight mode's `translate` policy on, translate key held) | follow leashed command | follow leashed command |
| tilting to steer (flight mode's `tilt` policy on, a tilt key held) | **relax** (snap setpoint → measured) | **relax** |
| hands-off (neither) | **hold** (setpoint frozen → arrest drift) | **relax** (coast) |

- "relax" = set `sp.swayPos/surgePos = meas.swayPos/surgePos` for that axis this tick (zero loop error → no counter-thrust).
- "hold" = leave the setpoint frozen at its last value (the loop drives residual velocity to zero).
- "follow" = the existing leash toward the commanded lead.

This replaces both the `policy.relaxTiltDrift` block and the coupled scheme's `decoupled` branch. The rule lives in `pilot.lua`, parameterized by (a) the flight mode's `tilt`/`translate` policy and (b) a `driftArrest` boolean from the master mode.

Boot default master mode: **CPL** (stabilized is the safe default; pairs with the LDG boot flight mode).

## 5. Forward trim — feedforward disturbance rejection

**Purpose (only this):** the craft pitches nose-up under forward thrust because its CoM is not vertically centered. Trim cancels that so the craft holds its intended pitch attitude.

**Signal — forward thrust command, not measured acceleration.** The pitch-up torque is produced by the forward thrust *force* acting through the CoM offset; that force (and torque) persists at terminal velocity where acceleration is ~0. So the physically correct, lag-free signal is the forward surge **demand**.

**Application.** In `fcs/runtime/loop.lua`, after `scheme:update` produces `demands` and before `envelope.clamp`:

```
demands.pitch = demands.pitch + trimDir * trimGain * demands.surge
```

Trim is **always applied** while a master mode is active (i.e. always — a master mode is always set). The TRIM button switches its *direction* (`trimDir` = +1 / −1), matching today's button, which has no off state; a craft that needs no trim uses `trimGain = 0` in config. There is no separate enable flag.

- Modifies the **pitch demand** → the mixer realizes it as a **lift-thruster pitch differential**. It never touches the forward thrusters (that would be braking, which fights the acceleration itself — explicitly unwanted).
- Downstream of the scheme, so it works uniformly in **all** flight modes with no per-scheme code.
- Clamped by the existing pitch cap / envelope. (Because it now applies in the flat modes too, whose pitch caps are tighter, trim may clip there — noted for the deferred effectiveness pass; canards are the pilot's physical fallback.)
- `demands.surge` is ~0 in DRN (no translate demand; forward motion is tilt-driven), so trim is naturally near-inert there — acceptable for this pass; revisit under effectiveness.

`trimDir` (+1 / −1) is toggled by the existing TRIM UP/DN button (`flightTrim` command). `trimGain`/`trimCap` come from feel. The dead `self.throttle`-based trim in `pilot.lua` is removed.

Layer needs: the **pilot** reads the master mode's `driftArrest` boolean (§4); the **loop** reads `trimDir` (and applies trim unconditionally while a master mode is set). Both are threaded from `Flight` (which owns master-mode state), or read from a small shared master-mode object — the implementation plan decides the exact seam.

## 6. DRN bugfix

DRN currently zeroes its horizontal thrusters in two places — both are bugs relative to intent:

1. `fcs/schemes/drone.lua` forces `d.sway, d.surge = 0, 0`. **Remove**, so the inner `Level` translate loop runs.
2. `fcs/io/tuningdefaults.lua` sets DRN caps `sway = 0, surge = 0`, which `envelope.clamp` erases to 0. **Raise** to real values.

Keep the drone keymap (WASD tilt, QE yaw, Space/LShift lift — no translate keys), so the pilot has no *direct* horizontal command. The §4 rule then gives the intended behavior for free: while tilting, horizontal hold relaxes (FCS holds altitude, doesn't fight the steer); on release, the horizontal loop stabilizes per the active master mode (arrest under CPL, coast under DCPL). DRN becomes "MAN with a tilt-only keymap and no direct translate keys."

## 7. Rampable climb

Lift ramp (tap = single-rate nudge, hold = ramps up to `climbRate*(1+climbBoost)`) currently lives inside the coupled `surge=="coupled"` branch. Lift it into the normal lift path in `pilot.lua` so it applies under any flight mode. Since a master mode is always active, this is effectively always-on; no gating needed.

## 8. UI

Keep **all seven buttons** — nothing dropped or merged. The change is selection grouping, not layout:

- Five flight-mode buttons (PRECISION / MAN / CRUISE / LDG / DRN): mutually exclusive **within the flight group** — one lit.
- CPL and DCPL: their own two buttons, mutually exclusive **within the master group** — one lit.
- The groups are independent: one flight button **and** one master button are lit at once (e.g. PRECISION + CPL). Pressing a master button changes only the master mode; a flight button changes only the flight mode.
- TRIM button unchanged, active whenever a master mode is set (always).
- All buttons reflect reported telemetry only — no optimistic UI (existing convention).

Telemetry gains a `masterMode` field (`"CPL"`/`"DCPL"`) alongside the existing `flightMode`; the UI's master-group highlight reads it. `trimActive` stops keying off `flightMode == "CPL"/"DCPL"` and keys off master state instead.

Command surface: a new `masterMode` command (`{ k = "masterMode", id = "CPL"|"DCPL" }`) mirroring the existing `flightMode` command path; `flightMode` command loses CPL/DCPL as valid ids.

## 9. Testing

Headless unit tests:

- **§4 truth table:** for each axis (surge, sway) × master mode (CPL, DCPL) × pilot state (translating / tilting / hands-off), assert hold vs. relax vs. follow (setpoint == frozen / == measured / == leashed).
- **Trim feedforward:** sign follows `trimDir`; magnitude ∝ `demands.surge`; zero when `trimGain = 0`; present across all 5 flight modes; never alters MAIN/forward-thruster duties (lift differential only).
- **DRN:** with the drone keymap and no translate keys, horizontal loop produces stabilizing output on release (CPL) and coasts (DCPL); altitude held while tilting.
- **Independence:** switching flight mode leaves master state untouched and vice versa; both persist across the switch.
- **UI:** two independent exclusive groups; one flight + one master lit simultaneously; highlights driven by reported `flightMode`/`masterMode`; TRIM active with a master set.

In-world flight tuning (trim gain, DRN caps, drift feel) stays manual.

## 10. Out of scope

Trim effectiveness / authority tuning (gain, per-mode pitch-cap headroom, canards), autopilot, any new sensor readers or modem channels, and changes to alt/attitude/heading control laws.
