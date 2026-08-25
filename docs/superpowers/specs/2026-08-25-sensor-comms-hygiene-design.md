# Sensor Comms Hygiene — Design Spec

**Date:** 2026-08-25
**Branch:** `refactor/comms-hygiene` (off `main` @ `pre-comms-refactor` / `a65eeae`)
**Status:** Approved design, pre-implementation.

## 1. Problem & goal

All three PCs (FCS, UI, NAV), every sensor, every device and redstone relay share **one wired
network**, so multiple PCs can (and do) call the same physical Aeronautics sensor blocks. Today:

- The **FCS** reads its 7 flight sensors every control cycle (needed).
- The **UI** *also* polls the gimbal + medial-velocity locally at ~10 Hz for the PFD attitude, and polls
  engine fuel at 2 Hz — duplicating reads the FCS already makes, plus its own.
- The **NAV** reads its *own* `navigation_table.getRelativeAngle()` for heading and relays it — a second
  reader of the same class of block the FCS already reads.

**Goal — communication hygiene:** the FCS becomes the **sole reader** of craft sensors and the **single
broadcast source**; every other PC consumes the FCS snapshot instead of polling. Keep only the reads that
are genuinely needed, and only where they're needed, with no duplicates and no background polling from
tools that only need a sensor while actively in use.

**Explicitly NOT in scope for this change:** reducing the FCS's own read set (all 7 are needed and stay),
changing the ground/parked behaviour, adding proximity warning, or re-verifying the CC:Tweaked
main-thread-vs-computer-thread cost model (tracked separately — the hygiene goal holds regardless of it).

## 2. Confirmed decisions

1. **Display calibration:** in `SENS SOURCE = FCS` the attitude/SAS shown uses the **FCS's** calibration.
   The UI's SELF-cal only affects the display when the operator explicitly picks `SENS SOURCE = SELF`.
2. **NAV heading depends on the FCS:** if the FCS telemetry is stale/down, heading shows stale ("---",
   the existing convention). Acceptable — the craft isn't flying without the FCS.
3. **Default `SENS SOURCE = FCS`** (snapshot-sourced), shipped as the default.

## 3. Current state (verified in source)

- **FCS snapshot** (`fcs/runtime/flight.lua` `Flight:snapshot`) already carries: `engaged, gndSafety,
  positionHold, fuelPump, parked, mode, flightMode, trimDir, altitude, vSpeed, heading, yawRate, swayPos,
  surgePos, onGround, loopHz, comAuto`, plus `thrusterFuel/fuelMain` added in the control task.
  **It does NOT carry `pitch`, `roll`, or `surgeVel`** — the UI's attitude comes from its own local poll.
  The FCS *does* compute pitch/roll/surgeVel every cycle (`fcs/io/backend.lua` `sensors()`).
- **Telemetry** is broadcast on channel **101** (`tools/flight.lua`), serialized whole
  (`textutils.serialise`), and the UI already receives it (`ui/basalt/app.lua` `routeModem` → `runtime.rx`).
- **UI polls:** local attitude ~0.1 s (gimbal + medial velocity via `ui/basalt/senssource.lua`
  `readAttitude`, producing `{pitch, roll, sas}`); fuel 0.5 s (`getFuelAmountMb`/`getFuelCapacityMb` on
  vault + tank, `app.lua` ~:390-414). The UI does **not** poll the 4 lateral opticals today.
- **UI `SENS SOURCE`** (`FCS`/`SELF`/`OFF`) today reads **locally even in `FCS` mode** — this is the root
  of the redundancy.
- **NAV** (`nav/runtime.lua`) reads its own navtable for heading and relays `{fix, heading, compass}` to
  the UI on its relay channel; it hears GPS beacons via an ender modem (`nav.comms.receiver`).

## 4. The design — four changes

### 4.1 FCS — extend the snapshot (small, cheap)
Add to `Flight:snapshot`: `pitch = m.pitch`, `roll = m.roll`, `surgeVel = m.surgeVel` (all already in
`meas`). FCS reads and control loop are otherwise **unchanged**.

**Heading — decided:** the snapshot's existing `heading` is the FCS's control-convention value
(`signHeading * headingScale * rawHeading`), which may not equal a true compass bearing. Rather than
assume they match, **always broadcast the raw magnet bearing as a distinct `compassHeading` field**
(= raw `getRelativeAngle`, magnet at true north — the exact value NAV relays today). `backend:sensors()`
already computes `rawHeading`; add it to the backend's returned `meas` and pass it through as
`compassHeading`. **All displays and NAV bearing math use `compassHeading`**; the control-convention
`heading` stays for control-related telemetry only. This guarantees the displayed bearing is unchanged
from today regardless of FCS heading calibration.

### 4.2 NAV — drop its sensor read, consume FCS heading
- Delete NAV's `navigation_table.getRelativeAngle()` read and navtable discovery/wrap
  (`nav/runtime.lua`, `nav/app.lua`).
- NAV **opens the FCS telemetry channel (101)** and takes `compassHeading` from the FCS snapshot for any
  internal use (waypoint bearing math), OR the bearing math moves to the UI — determine which during
  implementation by tracing where relative-bearing is computed today (an investigation task in the plan).
- NAV's outbound relay drops the heading field it used to source from its own navtable; it keeps relaying
  the GPS **fix** (position/groundspeed). The UI's heading now comes from the FCS snapshot, not NAV.
- Net: **one nav-table reader on the whole network — the FCS.** NAV does zero sensor polls.

### 4.3 UI — drop the auto attitude poll, re-route to the snapshot
- Remove the ~0.1 s local attitude poll loop in `ui/basalt/app.lua` (`startScheduled` task (f)).
- `M.buildState` sources `pitch/roll/sas` from `runtime.rx` (the FCS snapshot) instead of `runtime.state`
  (the deleted local poll), when `SENS SOURCE = FCS`.
- **`SENS SOURCE` semantics fix:** `FCS` = read from the telemetry snapshot (no peripheral touch); `SELF`
  = local read, used **only** during the active SELF-calibration procedure in BIT/CONFIG → SENS SOURCE
  (never in the background); `OFF` = nothing. Verify the SELF-cal capture flow already reads only on the
  CAPTURE action (on-demand), not on a timer — it should; no background sensor access remains for any UI
  tool when its menu isn't active.
- Lateral opticals: not added (prox warning is future).

### 4.4 UI — rate-limit the fuel poll
Engine fuel poll interval **0.5 s → 3 s** (`ui/basalt/app.lua` fuel task (c)). Redstone relay unchanged
(edge-only, dedup'd).

## 5. Data flow after the change

- **FCS** → broadcasts the extended snapshot on ch 101 at the existing telemetry rate.
- **UI** consumes: `runtime.rx` (attitude via pitch/roll/surgeVel, `compassHeading`, altitude, vSpeed,
  onGround, mode, flags) + its own 3 s fuel poll + NAV's GPS relay + FCS↔UI control comms (button-state
  edges) + dirty-gated renders. No background sensor polls.
- **NAV** consumes: FCS snapshot (`compassHeading`, if needed internally) + GPS beacons. Relays the GPS
  fix. **Zero sensor polls.**

## 6. Testing strategy

Unit / component (TDD, headless CraftOS + mocks — no real peripherals):
- FCS snapshot includes `pitch/roll/surgeVel` and `compassHeading` (= raw magnet bearing).
- `buildState` sources attitude from an injected `runtime.rx` snapshot; no dependency on a local poll.
- `senssource`: `FCS` mode returns telemetry-sourced attitude with **no** peripheral wrap/call; `SELF`
  mode still reads locally; `OFF` returns nothing. SELF-cal capture reads only on demand.
- NAV runtime: heading comes from an injected FCS snapshot; **no** navtable read; GPS fix still relayed.
- Fuel poll interval is 3 s.

End-to-end (the stated acceptance goal): a headless multi-PC harness that runs the FCS + UI + NAV with
mocked peripherals and asserts the **network traffic profile** while the FCS runs is *only*: FCS telemetry
broadcast, UI fuel poll every 3 s, NAV GPS beacon messages, and FCS↔UI control comms on control-button
edges — with **no** UI/NAV sensor polling and renders firing only through the dirty gate. Build on the
existing cockpit-assembly / suitex e2e harness.

## 7. Risks & mitigations

- **Attitude latency:** PFD attitude now arrives at telemetry rate (~10 Hz) instead of a 10 Hz local poll
  — equivalent. If telemetry is slower, tune the telemetry rate; keep the dirty gate.
- **Heading source swap** (NAV → FCS): the compass-heading caveat (§4.1) must be resolved so the displayed
  bearing stays true-north-correct. Covered by a snapshot-heading test.
- **Control-loop safety:** the only FCS change is *adding fields already computed* to the snapshot — no
  change to reads, mixing, or timing. Verify with the FCS control tests + an in-world check.
- **Thread-model uncertainty:** the exact main-thread-vs-computer-thread cost is unresolved (public-repo
  findings dispute the handoff txt; pending re-verification against the real jars). This design is correct
  for hygiene regardless — it removes duplicate/background reads either way.

## 8. Out of scope / future

- FCS ground-idle simplification (drop the `onGround`/`_parked` gate once GND-safety-off + engaged;
  optical only for a future landing/descent mode + prox/altitude warnings).
- Proximity warning (4 lateral opticals).
- Thread-model re-verification against the true Create-mod jars.
