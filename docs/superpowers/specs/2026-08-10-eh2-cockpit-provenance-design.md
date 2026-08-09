# EasyHover 2 — Basalt Cockpit + Config Provenance — design

- **Date:** 2026-08-10
- **Status:** approved in brainstorming (this doc is the review artifact before planning)
- **Scope:** ONE end-to-end spec covering four coupled subsystems, built from one plan. Ports the
  UI-PC cockpit to Basalt 2.0 (full), adds the new panels/menus, and introduces a config-provenance
  system (per-tool config files, an FCS boot-phase loader, a UI config-answer server, and a
  disk/data-cartridge courier). The FCS **flight control stack** (loops, mixers, PID, actuation)
  is **not** touched.

## Goal

Replace the UI-PC's custom immediate-mode cockpit with a Basalt 2.0 (full) multi-monitor cockpit,
add the NAV / A/P pages and a BIT/CONFIG hub of setup tools, and let every setup tool write a
canonical per-concern config file. On (re)boot the flight computer runs a small, isolated
boot-phase loader that lets the pilot choose, per config concern, whether to use the FCS's own
config, request it from the UI PC, or load it from a disk — then assembles it and hands off to the
unchanged flight app.

## Subsystems (one spec, clean seams)

1. **Config contract** — three canonical, separately-deletable config files (the seam every other
   part reads/writes).
2. **UI-PC Basalt cockpit** — the visible app: framework (multi-monitor, mirroring, FCS-safe
   cadence) + the top pages + the BIT/CONFIG hub.
3. **FCS boot-phase loader** — an isolated FCS-side startup program that assembles the runtime
   config from chosen sources and launches the flight app.
4. **FCS SYNC** — a UI-gated config-answer responder + a tiny request/reply protocol between the
   boot loader and the UI PC.

Plus the **DTC / disk courier** (a data-cartridge page + a networked disk drive), which is the
physical interchange for all three config files.

---

## 1. Config contract (the shared seam)

Three canonical config files, each owning ONE concern, each independently deletable for a hard
reset, all using EH2's existing additive-merge pattern (`fcs/io/hwconfig.merge`: saved values over
fresh defaults, deep-merged) and carrying a `schema` version:

- **`eh2_devbind.tbl`** — DEVICE BINDINGS: the 11 thruster slots
  (`FL FR RL RR YFL YFR YRL YRR MAIN FRL FRR`), the 7 sensor slots
  (`altimeter gimbal velFront velRear velMedial navTable downOptical`), and `fuelRelay` →
  peripheral-name strings (or `false`). Mirrors today's `hwconfig.defaults().thrusters/sensors/fuelRelay`.
- **`eh2_senscal.tbl`** — SENSOR CALIBRATION: the derived signs/scales/indices/offsets
  (`gimbalPitchIdx gimbalRollIdx gimbalScale signPitch signRoll signVelFront signVelRear
  signVelMedial signHeading headingScale signYawRate yawBaseline heightOffset onGroundThreshold
  baroThrusterOffset`). Mirrors today's `hwconfig.defaults().bindings` sub-table.
- **`eh2_tuning.tbl`** — CONTROL TUNING: gains/caps (`fcs/tuning.lua`) + pilot feel
  (`fcs/input/config.lua`). NEW file; defaults are the current committed checkpoint values.

**Why three, not one:** the FCS boot loader lets the pilot pick the source of *binding*, *sensor*,
and *tuning* **independently** (e.g. binding from disk, sensor from the UI, tuning defaults). That
independence requires three separate files. It also prevents the UI and FCS clobbering each other's
sections of a shared file.

**One format, two writers.** Whether a bare `tools/*` command (terminal fallback) or a Basalt
BIT/CONFIG menu writes a file, the bytes are identical — same keys, same schema, same
additive-merge + atomic tmp-then-move save. The bare tools came first and remain the reference
format; the Basalt menus reuse the same pure logic (see §Reuse map) so parity is structural, not
coincidental. This is asserted by tests (§Testing).

---

## 2. UI-PC Basalt cockpit

### Framework

- **Basalt 2.0 full**, loaded the same way SuiteX proved: `loadfile(path, nil, _ENV)` on a local
  `release/basalt-full.lua`. Getting Basalt onto the cockpit is one of two options (settle in
  planning): either the `ui` role **ships** `release/basalt-full.lua` in its file closure (simplest
  — it's always present after install), or the cockpit **ensures** it at startup exactly like
  SuiteX (`SuiteX.basaltAction` against `manifest.basalt`, fetch + verify + cache). The manifest
  already records `basalt`'s size+sum, so either path verifies against the same trust root.
- **Multi-monitor:** one Basalt frame per monitor via the frame's `term` property
  (`frame:setTerm(monitorPeripheral)`); Basalt keys active frames by terminal and one
  `basalt.run()` drives all monitors + the computer terminal. Monitor→page **assignment and
  mirroring** are preserved from today (`ui/monitors.lua` resolve/route logic reused); the terminal
  always hosts the Config page.
- **Comms stays live inside Basalt.** The cockpit must keep receiving telemetry and sending
  commands while rendering. Telemetry receive / command retry / engine tick / fuel poll become
  Basalt-integrated work (registered `modem_message` handling + `basalt.schedule` coroutines / a
  Basalt `Timer`), NOT a separate `parallel.waitForAny`. The proven `basalt.schedule` mechanism
  (used by SuiteX) is the model.
- **FCS-safe cadence (hard constraint, [[feedback-ui-cadence-rules]]):** the cockpit is
  event-driven → a quantized state model → dirty-gated → diff-rendered. Basalt only pushes a frame
  to a monitor when that frame is dirty; the cockpit marks frames dirty **only** on a real,
  display-visible change (reusing today's `renderSig()` quantization idea), never on every telemetry
  message or engine tick. This is the exact discipline that fixed the FCS-starvation bug (`50d7708`)
  and it MUST survive the port. No optimistic UI ([[feedback-no-optimistic-ui]]): panels show
  reported state only.

### Top pages (monitor-assignable)

Assignable set grows to **Config · EMC · FCS · NAV · A/P**. Each existing panel's *logic* (what to
show, what a touch does) is reused from `ui/panels/*`; only the render/hit model changes from
"return a drawlist" to "build Basalt elements once, update via setters on change."

- **EMC** (was `engine`) — port as-is: PUMP/TANK gauges, feed status, ON/OFF/PRIME, timings.
- **Config** — port as-is (monitor assignment + device summary); terminal-hosted.
- **FCS** — port current content (engage / disengage, GND-safety with engage-blocked-while-safe,
  MODE/ALT/VSPD/HDG/LOOP/LINK overview) **plus a row of placeholder MODE buttons** (disabled /
  "soon"; the FCS modes are the next project). **POS HOLD + CLR DAMP move OFF this page** to A/P.
- **A/P** — **POS HOLD + CLR DAMP** (real commands, moved from FCS — they are the two A/P functions
  we already have), with room to grow (att/alt/speed hold, direct-to-waypoint, routing, flight
  plans come from a later A/P source). Crowding later is expected and fine.
- **NAV** — a placeholder body (where the NAV render lands later) + one working **`[BIT/CONFIG]`**
  button at the bottom.

### In-monitor drill-down navigation

Submenus are drill-downs within a monitor's page (a small nav stack), NOT new monitors. Each
sub-screen carries a **`< Back`** button. Path: `NAV → BIT/CONFIG → { FCS Tuning | MDB-Conf | UI CAL
| SENS CAL | DTC | FCS SYNC }`. FCS Tuning, MDB-Conf, SENS CAL, DTC, FCS SYNC are leaf screens under
BIT/CONFIG.

### BIT/CONFIG hub (6 entries)

1. **FCS Tuning** — Basalt steppers over the tuning parameter set (per-axis gains + caps + feel),
   grouped/paged for the monitor size. Writes **`eh2_tuning.tbl`** (deletable). Not live-wired to
   the FCS this cycle — it takes effect when the boot loader loads it and the FCS reboots.
2. **Manual Device Binding (MDB-Conf)** — a native Basalt binding workflow: enumerate network
   peripherals (topology is one shared wired net, so the UI sees the thrusters/sensors), assign
   them to the 18 slots + relay. Writes **`eh2_devbind.tbl`**, byte-identical to the bare tool's
   format.
3. **UI CAL** — the existing UI device logic (scan / bind relay + pump + tank, cal-fuel, relay
   side), reused from `ui/*` (Detect/Fuel/Engine + the Config panel's actions), **minus** the
   monitor-assignment bits. Writes the UI's own device config (`/eh2_ui_config.tbl`, as today).
4. **Sensor Calibration (SENS CAL)** — a native Basalt guided calibration (NOT a launch of the
   terminal tool): reuses `fcs/io/calibration.lua` (all `classify*`/`compute*` math),
   `tools/calibrate.lua`'s pure `M.*` apply/`average`/`peakByAbs`/`argmaxAbs` helpers, and its
   `stream()` sampling — wrapped in Basalt steps ("hold LEVEL → capture", "tilt NOSE UP → capture",
   accept/reject, progress) driven on a `basalt.schedule` coroutine so the UI never blocks. Reads
   `eh2_devbind.tbl` for the sensor names; writes **`eh2_senscal.tbl`**, byte-identical to the bare
   tool. Runs on the UI PC (sensors are on the shared network; `calibrate` already ships to the
   `ui` role).
5. **DTC (Data Cartridge)** — detect/refresh the disk in the networked drive; **export** all three
   config files to it; **import** from it to overwrite the local copies. The disk is the universal
   courier between PCs (§DTC).
6. **FCS SYNC** — start/stop the config-answer responder; show "server running?" and "FCS
   connected/requesting?" (§FCS SYNC).

---

## 3. FCS boot-phase loader (isolated)

A **separate program**, not part of the flight runtime — its own files, its own tasking, a plain
CC **terminal** UI (no Basalt on the FCS boot path: keeps the FCS install light and the boot path
dependency-free). It becomes what the FCS role's `startup.lua` runs first; on success it launches
the flight app and exits, so nothing of it runs during flight.

**Flow** (config concerns in the order the pilot needs them: binding → sensor → tuning):

- **Binding** source: **Own** (`eh2_devbind.tbl` local) · **Request from UI PC** · **Load from disk**
- **Sensor** source: **Own** (`eh2_senscal.tbl` local) · **Request from UI PC** · **Load from disk**
- **Tuning** source: **Request from UI PC** · **Load from disk** · **Load defaults** (the committed
  checkpoint `fcs/tuning.lua` values)

**Indicators:** progress, disk state (present / valid / label), and which configs are available per
source. **Validation:** every chosen file is unserialised + schema/shape-checked; a corrupt file is
refused with a clear message and the pilot re-picks (never silently used). **Handoff:** once all
three are chosen and valid, the loader assembles the runtime config — writes `/eh2_hw_config.tbl`
(`thrusters/sensors/fuelRelay` from the chosen devbind + the `bindings` cal sub-table from the
chosen senscal, in today's `hwconfig` schema, so the **flight app's hw_config read is unchanged**)
and `/eh2_tuning.tbl` — then runs the flight app and exits.

**Robustness (must-haves):** "Request from UI PC" uses a **timeout + retry**, and on no-answer
shows a clear fallback message ("UI SYNC not responding — start FCS SYNC on the UI, or pick Disk /
Own / Defaults") so a mis-ordered dance never hangs the boot.

---

## 4. FCS SYNC (protocol + gated responder)

The cockpit already runs a comms loop for telemetry, so this is not a new always-on OS task: it is a
**flag-gated responder** inside the cockpit's event handling, **off by default**, plus a status
surface. The FCS SYNC BIT/CONFIG page exposes **Start / Stop** and shows **running?** and **FCS
connected/requesting?**.

**Protocol** (reuses `fcs/comms/modem` + a dedicated channel, latest-wins request/reply):

- Boot loader → UI: **`hello`** (I'm booting) — lets FCS SYNC display "FCS connected."
- Boot loader → UI: **`req{concern}`** (`devbind|senscal|tuning`).
- UI (only when the responder is Started) → boot loader: **`cfg{concern, body}`** — the serialized
  file contents. When Stopped, the UI does not answer (boot loader times out → fallback message).

**Workflow:** enter FCS SYNC → Start → reboot FCS → FCS enters boot phase and sends `hello` → FCS
SYNC shows connected → pilot picks "Request from UI PC" per concern → UI serves each → boot finishes
and launches the flight app → Stop → close the menu.

---

## 5. DTC / disk courier

A **disk drive on the wired network** with an insertable disk. The **DTC page** (UI, under
BIT/CONFIG): detect/refresh the disk (show label + which config files it holds), **export** all
three config files to it, **import** from it to overwrite the local copies. The **boot loader** can
also read any of the three files directly off the disk ("Load from disk"). The FCS never *depends*
on a disk — the disk is opt-in provenance, with Own/Request as alternatives.

---

## FCS-side changes (minimal; flight runtime frozen)

The flight **control stack** (loops, mixers, PID, actuation, comms cadence) is untouched. The FCS
repo gains only:

1. **`fcs/tuning.lua` reads `eh2_tuning.tbl` over its hardcoded defaults** (additive merge) at load
   time — a boot-time read, no flight-loop task. This is the single "wiring" that makes UI tuning
   take effect (on reboot).
2. **`tools/calibrate.lua` writes `eh2_senscal.tbl`** (the cal sub-table) instead of the combined
   `/eh2_hw_config.tbl`, so the bare tool and the UI share one format. It still reads devbind for
   sensor names. (Small change; stays a terminal fallback.)
3. **A bare device-binding writer** for `eh2_devbind.tbl` (parity fallback for MDB-Conf) — new small
   `tools/` command.
4. **The boot-phase loader program** + the FCS role's `startup.lua` running it before the flight
   app. New, isolated files; no flight-runtime coupling.

All four are boot-time / tooling; none adds a task while the FCS is engaged in flight.

---

## Migration / back-compat (no existing config is lost)

Existing installs already carry a populated `/eh2_hw_config.tbl` (real calibrated values —
`signHeading`, `heightOffset`, device bindings, …) and `/eh2_ui_config.tbl`, and have **no** tuning
file yet. Updating to the split-file model must preserve all of it with **zero recalibration**:

- **Legacy read-through on "Own".** When the new split files are absent, the boot loader's **Own**
  binding/sensor sources (and the FCS's own tools) derive them from the legacy `/eh2_hw_config.tbl`:
  `thrusters/sensors/fuelRelay` → `eh2_devbind.tbl`, the `bindings` sub-table → `eh2_senscal.tbl`.
  So the first post-update boot picks up the existing binding + calibration automatically.
- **Runtime path unchanged.** The boot loader still assembles and writes `/eh2_hw_config.tbl` for
  the flight app, so the flight runtime reads the same file at the same path as today — the split is
  invisible to it.
- **Tuning defaults ARE the checkpoint.** `eh2_tuning.tbl`'s defaults are the committed known-good
  `fcs/tuning.lua` values, so an absent tuning file (every current install) yields byte-for-byte the
  current flight behavior; "Load defaults" restores it any time.
- **UI config untouched.** `/eh2_ui_config.tbl` is read/written by UI CAL exactly as today.
- **Additive-merge everywhere.** Every config load is saved-over-fresh-defaults (`hwconfig.merge`),
  so a partial or older-schema file still loads and only missing keys fall back to defaults —
  updates never blank a config. Writes stay atomic (tmp-then-move).
- **Non-destructive split.** Writing the new split files does not delete the legacy
  `/eh2_hw_config.tbl`; it remains as the "Own"/legacy source until the split files supersede it.

This is asserted by migration tests (§Testing): a legacy `hw_config` fixture → split files → assembled
`hw_config` round-trips to the same values.

---

## Reuse map (parity by construction)

- **SENS CAL (Basalt)** ⟵ `fcs/io/calibration.lua` (`classifyGimbalAxis`, `classifyLateralPair`,
  `classifyScalarSign`, `headingSignScale`, `computeHeightOffset`, `computeGroundThreshold`) +
  `tools/calibrate.lua` `M.*` (`applyGimbal/applyLateral/applyScalarSign/applyHeading/applyGround/
  applyConstants`, `average`, `peakByAbs`, `argmaxAbs`, `stream`) + `fcs/io/shim` (sensor wrap).
- **MDB-Conf (Basalt)** ⟵ the `eh2_devbind.tbl` schema (`fcs/io/hwconfig` slots) + peripheral
  enumeration; parity fallback = the new bare binding writer.
- **UI CAL (Basalt)** ⟵ `ui/detect.lua`, `ui/fuel.lua`, `ui/engine.lua`, and the Config panel's
  scan/bind/cal-fuel/relay-side actions.
- **Panels (Basalt)** ⟵ `ui/panels/{fcs,engine,config}.lua` logic; `ui/monitors.lua` assignment +
  mirroring.
- **Config I/O** ⟵ `fcs/io/hwconfig.merge` (additive merge) + the atomic tmp-then-move save.
- **Basalt bootstrap + theming + cadence** ⟵ patterns proven in `easyhover2_suitex.lua`.

---

## Testing strategy

- **Pure, headless-tested (TDD):** the config file schemas + additive-merge + validation; the
  boot-loader's source-selection/assembly logic (given chosen files → assembled hw_config + tuning);
  the migration round-trip (legacy `/eh2_hw_config.tbl` fixture → split devbind+senscal → reassembled
  `hw_config` equals the original values — proves no calibration is lost on update);
  the FCS SYNC request/reply state machine (hello/req/cfg, started/stopped, timeout); DTC
  export/import file mapping; MDB slot assignment; **parity tests** asserting a Basalt-path config
  equals the bare-tool's for the same inputs; the panels' view-models/actions; the render dirty-gate
  signature.
- **Basalt rendering:** single-frame render via `basalt.update("timer", -1)` (never `run()` in
  tests); a CraftOS-PC construction probe for each new panel/menu (like SuiteX's), asserting the
  element tree builds + renders one frame.
- **Comms/boot:** mock modem + mock disk to exercise the boot loader ↔ FCS SYNC exchange headlessly.
- **In-game:** multi-monitor smoke + screenshots for visual sign-off; a real reboot through the boot
  phase choosing each source.
- **Guards:** `tools/run_gen.sh --check` (manifest IN SYNC) + `tests/run_headless.sh` green gate
  every change; new test files registered in the runner.

---

## Non-goals (this cycle)

- The FCS flight **modes** (FCS-page MODE buttons are placeholders — next project).
- Real A/P modes beyond POS HOLD + CLR DAMP (att/alt/speed hold, waypoints, routing, plans).
- The NAV render itself (NAV page is a placeholder body + the BIT/CONFIG button).
- Any change to the flight **control** stack (loops/mixers/PID/actuation).
- Live (in-flight) tuning application — tuning applies at FCS boot, by design.

## Open items (not blocking; settle during planning)

- Exact tuning parameter set + grouping/paging for the monitor size (propose: all of
  `fcs/tuning.lua` gains/caps + the `fcs/input/config.lua` feel values, grouped by axis).
- The FCS SYNC channel number + framing (reuse an existing channel vs. a new one).
- Whether MDB-Conf offers a test-pulse to identify which physical thruster is which (nice-to-have;
  the UI can drive a thruster on the shared net) or binds by known IDs only.
- Final logo/theme reuse from SuiteX for the cockpit chrome.
