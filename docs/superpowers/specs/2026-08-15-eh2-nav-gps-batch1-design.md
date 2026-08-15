# EH2 NAV + A/P — Batch 1: Broadcast GPS + NAV/beacon roles (design)

## Problem & goal

EasyHover 2 has no absolute positioning. The FCS senses altitude, attitude, body-frame
velocities and a *relative* heading, and dead-reckons X/Z (which drifts). The full NAV +
autopilot package (ALT HOLD, WAYPOINT, RTB, routes, autoland, NAV map) all rest on knowing
*where the craft is*. We build the package in batches. **Batch 1 delivers the positioning +
heading foundation and its config/monitoring UIs, and proves the base GPS works without slowing
the flight software.** It touches **zero existing flight code** (two brand-new Suite roles).

## The new GPS: broadcast, not request

Deliberately unlike EH1's request-based CC `gps.locate()` (the craft pings, beacons reply). The
EH2 GPS is **push**: beacons periodically *transmit* their positions on a UI-configurable modem
channel over **ender modems** (global range in-dimension); receivers listen passively.

**Mechanism:** CC attaches a `distance` field to every same-dimension wireless `modem_message`.
So a beacon broadcasting `{id,x,y,z}` gives every listener that beacon's coordinates **and** its
distance — enough to trilaterate a receiver's own position from 4 beacons with the receiver
transmitting nothing. Multiple craft can share one broadcast. The broadcast also **doubles as the
beacon mesh**: every beacon hears the other three, so it can self-check (measured vs configured
peer distances → typo detection), list the constellation, and grade GPS quality — no second
protocol. Coexists independently with the still-working EH1 GPS on its own channel.

## Non-negotiable: no FCS starvation

CC has a shared server budget (`computer_threads` pool + ~10 ms/tick main). Forecloseable and
foreclosed:
- Beacons are **event-driven and sleep between broadcasts** (never busy-wait). Idle computers cost ~0.
- Broadcast interval is **configurable with a 1 Hz default floor**; 4 msgs/s is negligible.
- Reception + trilateration live **only on the NAV pc**; the **FCS never opens the GPS channel**
  (zero event-queue cost to it).

## Scope

**IN:**
- **beacon** role — basic computers, keyboard `term` UI (no Basalt, monochrome-safe, severity in text):
  set exact position, verify vs peers, list the 4-beacon network + live GPS quality, broadcast settings.
- **nav** role — advanced pc, Basalt 2 UI (tabs / drilldowns): live position / heading / quality + all
  devices & settings configurable.
- Broadcast GPS protocol (beacons → listeners), UI-configurable channel + interval, ender modems.
- NAV position fix via **multilateration** from ≥4 beacon broadcasts (coords + CC `distance`).
- **Heading:** NAV reads its *own* `navigation_table` (magnet → true north) → absolute heading, with
  sign calibration in the UI.
- **Constellation quality grading:** 4-host requirement, min-separation, coplanarity (tetrahedron volume).
- **Beacon self-check:** measured peer distances vs configured coordinates → typo/misconfig detection.
- NAV **connects to the craft wired network and relays** position/heading frames (FCS ignores them).

**OUT (later phases):** waypoints, routes, autopilot modes (HOLD/GOTO/ROUTE/RTB/AUTOLAND), autoland,
NAV map/route visualization, FCS *consuming* the fix. (The A/P page already reserves disabled
placeholders ALT HLD / WAYPOINT / RTB.)

## Architecture

- Two new roles installed via the Suite role picker. New source dirs `nav/` and `beacon/`, new
  launchers, new manifest role entries in the closure. NAV reuses the EH2 Basalt UI stack; beacon
  ships no Basalt.
- **Broadcast frame:** `{ id, x, y, z, seq }` on the configured channel. Receivers key on the
  `modem_message` `distance` arg.
- **Fix record:** `{ x, y, z, age, quality, source, nBeacons }` — downstream (Phase 2) can refuse a
  stale/low-quality fix.
- **Degrade-safe:** <4 usable beacons or a degenerate (coplanar) geometry → no fix, annunciated.

## Key modules & reuse

- Port EH1 `EasyHover/gps_beacon/lib/geometry.lua` → EH2 pure `nav/lib/geometry.lua` (host count /
  min-separation / coplanarity grading), reused by both roles.
- New pure modules (all TDD): `nav/lib/trilaterate.lua` (multilateration solver; rejects
  mirror/degenerate cases EH1 relied on CC's `gps.locate` to handle), `nav/lib/heading.lua`
  (navtable relative-angle → absolute heading + sign cal), `nav/lib/fix.lua` (assemble/age/quality-tag).
- Broadcast link on the EH2 `fcs/comms/modem.lua` + `fcs/comms/protocol.lua` Link/frame patterns.
- Config/persistence via the EH2 `fcs/io/config.lua` + `cfgspec.lua` patterns.
- NAV Basalt UI reuses `ui/basalt/*` (regions/pages, `picker.lua`, `switchbtn.lua`, bitconfig hub
  drilldown pattern). Beacon UI follows EH1's keyboard beacon-screen shape.
- Reference docs: `EasyHover/docs/NAVIGATION.md`, `EasyHover/docs/GPS.md`.

## Verification

- **Unit (CraftOS-PC headless, TDD):** trilaterate (known constellations, mirror rejection, <4 hosts),
  geometry grading, heading (angle→compass + sign cal), broadcast frame encode/decode, beacon
  distance-consistency self-check.
- **Basalt UI:** single-frame render tests (`basalt.update("timer", -1)`) with mocked `modem` +
  `navigation_table` peripherals (extend `tests/mocks`).
- **Integration:** mocked 4-beacon broadcast stream → NAV computes correct fix + quality tier + typo detect.
- **In-game:** deploy 4 beacons + NAV via the Suite; verify fix vs known coords, quality grading,
  beacon typo detection, heading vs facing; connect NAV to the craft wire; confirm no FCS TPS impact.
- **Suite gates:** source + dist headless suites green, e2e phases green (add `nav`/`beacon` install +
  switch phases), `run_gen.sh --check` IN SYNC; `dist/` regenerated for the two new roles.

## Rollout

Branch `nav-gps-batch1` → TDD pure modules → role runtimes + UIs → Suite integration (manifest
closure, launchers, dist, both suite lists, e2e) → full gates → whole-branch review → merge + push.
Beacons/NAV install via `wget run` Suite role picker; runs on its own channel, independent of EH1
GPS. Then brainstorm Phase 2.
