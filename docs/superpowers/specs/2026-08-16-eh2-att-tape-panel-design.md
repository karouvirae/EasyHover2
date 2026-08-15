# EH2 Attitude / Heading-Tape Panel (PFD) — design

Phase-2 NAV UI for the EasyHover 2 **UI-role** cockpit: a dedicated panel with two animated
instruments — a **heading tape** and an **FPM-style attitude indicator** — plus **ALT** and **SPD**
readouts. The flight-proven FCS stays **untouched**. Brainstorm memory: `nav-ui-pfd-brainstorm`.

## Scope

**In:** the dedicated att/tape panel (a new UI-role cockpit page) + the local sensor/calibration
plumbing that feeds it.

**Out (separate later batch):** the NAV data-page rework — `[BIT/CONFIG]` pinned to the bottom row,
the waypoint/route screen, and the ALT/SPD **display-source** quick-switch. (The user will elaborate
the waypoint/route UI later.)

## The panel — one dedicated page, one Basalt frame, one redraw

```
┌────────────────────────────────────────┐
│ 340   350   000   010   020            │  heading tape: scrolls under a fixed ^ lubber
│              ^                          │  (~2-3 deg/cell, tick /10, label /30, N/E/S/W)
│                                         │
│ - - - - - - - - - - - - - - - - - - - - │  fixed subpixel-dashed horizon @ mid-height (drawn once)
│              -| O |-                    │  hollow circle + wings = craft; up/dn = pitch, tilt = bank
│                                         │
│                            ALT 087Baro  │  ← lower-right; shares the same apply()/render pass
│                            SPD 012SAS   │
└────────────────────────────────────────┘
```

- **Heading tape (top):** horizontal, fixed center lubber (`^`), tape scrolls under it. Defaults
  (adjustable): ~2–3° per cell, tick every 10°, label every 30°, cardinal letters at N/E/S/W, current
  heading as a number at the lubber. **Cell-granular interpolated scroll** (the agreed "smooth
  interpolated" fidelity — not stepped, not subpixel).
- **Attitude indicator (center), FPM style:**
  - **Fixed horizon** at the frame's **mid-height**, **subpixel-dashed**, **drawn once** (static →
    ~zero per-frame cost). Provide an **ASCII dashed fallback** (`- - -`) and verify the chosen
    drawing glyphs against the REAL CC:Tweaked font before trusting the subpixel version
    (`reference-cct-font-ascii` — CraftOS-PC's font lies about extended glyphs).
  - **Hollow circle** = craft body; translates **vertically** with pitch (below the line =
    pitch-down, above = pitch-up).
  - **Small wings** flank the circle, each ending in a **short vertical line**, **full
    character-cell**; the wings **tilt/rotate around the circle** for bank, **cell-stepped** (no
    subpixel).
  - Only the moving symbol's own cells repaint.
- **ALT readout (lower-right):** `ALT: <n>Baro` | `ALT: <n>GPS`. **Default this batch = Baro.**
- **SPD readout (lower-right):** `SPD: <n>TAS` | `SPD: <n>SAS`. **Default this batch = SAS.**
  (TAS = GPS ground speed, labelled TAS since true airspeed would vary with altitude — likely
  unmodelled in MC; SAS = the fwd/bkwd surge-velocity sensor.)

## Render / cadence

One page = one frame; **tape + attitude + ALT + SPD all render in the page's single `apply()`** on
the existing **dirty-gate** — **no fixed-rate timer** (update like the current panels). `cadence.sig`
gains quantized `pitch / roll / heading / baroAlt / gpsAlt / surgeVel(SAS) / groundSpeed(TAS)`; repaint
only when a quantized value steps. **Quantization granularity is the sole load lever** (coarser steps
→ fewer repaints) if it ever needs throttling. Sensor polls live **off the render path** (see below).

## Data sources & the instrument-state contract

The panel is driven by a pure **instrument-state** table (the seam between the two sub-batches):

```
{ pitch, roll,            -- degrees, calibrated (local sensor read)
  heading,                -- degrees (FCS telemetry)
  baroAlt,                -- FCS telemetry `altitude`
  gpsAlt,                 -- NAV fix Y (relay ch 107)
  sas,                    -- surge speed (local surge sensor, calibrated)
  tas,                    -- GPS ground speed (NAV relay)
  altSource, spdSource,   -- "Baro"/"GPS", "TAS"/"SAS" (default Baro/SAS this batch)
  gpsFixOk }              -- fix present + fresh + quality good enough to trust GPS sources
```

| Field | Source | Notes |
|---|---|---|
| pitch, roll, sas | **UI reads gimbal + surge sensors LOCALLY** | scheduled poll loop OFF the render path (non-mainThread → cheap); calibrated per SENS SOURCE |
| heading, baroAlt | **existing FCS telemetry** | already sent — NO flight.lua change |
| gpsAlt, tas | **NAV relay ch 107** | NAV adds ground speed to its frame; gpsAlt = fix.y |
| gpsFixOk | NAV fix quality/age (GDOP-aware) | GPS sources render only when true, else `---` (never a stale number) |

**The FCS is untouched.** NAV change is minimal (relay `+= groundSpeed`, horizontal Δfix/Δt). The UI
gains the ch-107 listener, the sensor poll loop, the new page, and the SENS SOURCE submenu.

## Calibration — `SENS SOURCE` (two switchable sources; the inactive one is fully no-op)

Raw gimbal/surge readings are meaningless without calibration (which gimbal index is pitch vs roll,
signs, deg/rad scale; surge sign/scale). Two sources, switchable, **both** built (user wants the
modularity):

- **`SENS SOURCE = FCS`** — fetch the FCS's calibration (gimbal axis/sign/scale + surge sign/scale)
  via the existing cfgsync/disk provenance path, apply it to the raw reads.
- **`SENS SOURCE = SELF`** — the UI's own tiny sign/scale calibration (level-the-craft + known-tilt
  capture, mirroring the FCS's calibration idea but display-only), stored locally on the UI.
- A **`SENS SOURCE` submenu** in the UI cockpit **BIT/CONFIG hub** selects the active source. **The
  unselected source is fully inert** — no fetch, no cal run, no sensor read under that path.

## Prerequisite (in-world, user to confirm)

The **gimbal + surge-velocity sensors must be on the shared wired network reachable by the UI PC**
(not wired only adjacent to the FCS), or the UI can't wrap them. If they are FCS-adjacent-only, they
need to go on wired modems.

## Build decomposition — two sub-batches (seam = the instrument-state contract)

- **Batch A — the panel (visible, fully unit-testable against a MOCK state).** Heading tape + FPM
  attitude indicator + ALT/SPD readouts as **pure view-models + Basalt rendering**, driven by a mock
  instrument state; the subpixel-horizon helper + ASCII fallback (both tested). **Zero** sensor/cal
  work. Delivers the visible panel and pins the contract. → spec this one first.
- **Batch B — the data + calibration.** Fills the contract for real: the UI gimbal/surge **poll loop**
  + **both cal sources** + `SENS SOURCE` submenu + **self-cal flow** + **FCS-cal fetch** (cfgsync/disk)
  + **ch-107 listener** + **NAV relay `+= groundSpeed`** + **cadence-sig additions**.

A-then-B lets the panel be *seen* (against test data) before the sensor/cal plumbing lands, and keeps
the risky calibration work isolated behind a clean interface.

## Testing (both batches, TDD)

Pure view-models: tape tick positions + interpolated scroll offset; attitude symbol cell placement +
wing rotation per bank; ALT/SPD formatting (source suffix) + degrade to `---` when `gpsFixOk` is
false. Basalt render probes (`basalt.update("timer", -1)`, never `basalt.run()`). Subpixel-horizon
helper with ASCII fallback (both paths). Cadence-sig additions. SENS SOURCE inactive-path no-op.
Cal-source correctness (FCS-fetch application; self-cal capture math). Full build for the UI role
(`basalt-full.lua`).

## Open / to confirm

- Sensor wiring prerequisite (in-world).
- Heading-tape visual defaults (span / deg-per-cell / ticks) — adjustable during Batch A.
- Compact merged-flight-page variant — deferred unless wanted.

## Reuse

UI cockpit page interface + bootstrap (`ui/basalt/app.lua`, `ui/basalt/nav.lua`,
`ui/basalt/region.lua`, `ui/basalt/switchbtn.lua`, `ui/basalt/configkit.lua`, the `bitconfig/*`
drilldown pattern for the SENS SOURCE submenu). Cadence dirty-gate (`ui/basalt/cadence.lua`). NAV
relay + fix (`nav/runtime.lua`, `nav/comms/*`, ch 107). Simulated sensor API notes
(`reference-simulated-propulsion-cc-api`: instrument sensors are NOT mainThread). Font safety
(`reference-cct-font-ascii`). Basalt full build (`feedback-basalt-full-build`). Cadence house rules
(`feedback-ui-cadence-rules`).
