# HANDOFF -- EasyHover 2 feature-complete pre-test sweep

**Date:** 2026-08-30
**Repo:** `C:\Users\m-kri\Claude Code\EasyHover2` · `main` @ `ff4a73f` (clean, matches origin)
**Status:** source audit, then re-verified against EH2 + CC:T / Basalt 2.0 / Propulsion / Simulated notes. Not an in-world flight.

This is the working list for the Minecraft full test and the follow-up fix pass. A/P, TRK-as-mode, PROX WRN, PFD Baro/GPS · SAS/TAS switch, and GitHub #10 stay out of must-fix unless a control looks live and would lie.

Legend:

| Tag | Meaning |
|---|---|
| KEEP | Real bug / spec miss |
| KEEP, refined | Still true; narrower trigger than the first pass |
| DOWNGRADE | Not a pre-test bug (design, leftover chrome, or footgun) |
| SPEC | Matches a written spec; still a test caveat |

Fix order if we start coding: **A1, then B1, then A3**.

---

## Pre-test briefing (verified)

1. Boot is **LDG + CPL**, not PRECISION.
2. Do **not** leave CRUISE by tapping PRE after a W-release detent (A1).
3. Do **not** flip engine latch without rebooting the UI PC (A3).
4. POS HOLD / CLR DAMP are on the A/P monitor (B3).
5. EMC CONFIG taps may sit until the next fuel poll if the ship is idle (B1).
6. Assign every monitor (B6).
7. Yaw and watch the PFD tape vs the turn -- `compassSign` may be unflipped (D1).
8. Close PARAMS before rebooting the UI PC (spec: extras can stick on the wire).

---

## A -- Fly-risk

### A1. CRUISE + CPL slam when leaving CRUISE -- KEEP

**Spec violation.** Flight-modes spec: "leaving CRUISE zeros the held surge." Code zeros **throttle** only, not `sp.surgePos`.

- CRUISE policy: `surge = "throttle"`, `translate` nil, so the **position leash still runs**.
- Scheme then throws that demand away: `d.surge = sp.surgeThrottle` (`fcs/schemes/cruise.lua:8-11`).
- Default master is CPL: on W-release the leash **freezes** the setpoint while MAIN keeps the detent (`fcs/input/pilot.lua:91-115`).
- `meas.surgePos` keeps integrating (`fcs/io/backend.lua`).
- Mode switch: `loop:setActive` -> `scheme:reset()` (I = 0) but **no** `pilot:reset(meas)` (`fcs/runtime/flight.lua:83-102`).
- Next PRECISION tick: Translate P-term `kp * (sp - meas)` with `kp = 0.15`, cap `1.0` -> rails.

| Pilot action | Error | What you feel |
|---|---|---|
| Tap PRE **while holding W** | leftover lead ~ `surgeLead` (10-20 blk) | full **forward** main |
| Cruise, **release W** (detent), then tap PRE | meas walks past frozen sp | full **frontal brake** |

DCPL hides it (hands-off snaps `surgePos` to measured).

Not a Propulsion issue. Surge is our setpoint math; `setPower` is 16-step `mainThread` as designed.

### A2. LDG tilted pad hops -- KEEP, refined (test caveat + dead code)

Not a contradiction of the LDG spec. `_ldgLanded` **refuses** park if `|pitch|/|roll| > 0.12 rad` (~7 deg). Optical `onGround` still freezes **all** PID I/D (`Loop:cycle` passes `grounded` into every axis; P still runs). HoverDuty then fires -> hop.

- `moveEps` is stored and **never read** (old ground-idle leftover).
- Engage comments still describe the deleted `_parked = onGround AND atRest` gate.
- PRECISION / MAN / CRUISE never auto-park -- by spec.

**Test:** level pad in LDG. A few degrees of tilt will not latch. Optical `getDistance` is not `mainThread` (Simulated instruments).

### A3. Latch/basic flip does not take effect until UI reboot -- KEEP, refined

`Engine.mode` is snapshotted in `Engine.new`. `applyConfig` only swaps `cfg` + clears `lastWritten`. `makeEngineWriter` runs **once** in `buildRuntime`. UI CAL `cycleMode` writes config, rebinds, `blockNow` -- live writer type unchanged.

**Drain is not automatic.** It bites if hardware and live machine disagree:

- Boot **basic**, build a Powered Latch, set mode=latch, **no reboot** -> still pulses `config.relay.side`. Latch BLOCK line never fires. If the old side is disconnected, funnel unpowered = open = vault drain.
- Boot **latch**, flip to basic in UI -> still pulses latch lines.

`blockNow` after the flip still uses the **old** machine, so it is safe only for the hardware you booted with.

CC:T `redstone_relay.setOutput` is not `mainThread`. This is writer-selection, not tick budget.

### A4. FCS `noFuel` does not stop the UI chute -- KEEP (architecture)

Two different tanks:

- FCS: mean of lift-thruster `getFuelAmountMb` at 1 Hz (decoupled). Empty Create fluid -> disarm. Does not talk to the UI relay.
- UI ENG SW: solid chute via invert funnel. No `noFuel` / `fuelPump` gate. FCS `fuelPump` command has **no UI sender**.

Propulsion: unfuelled thruster holds last `setPower` and produces zero thrust. That is why the FCS interlock exists. It does not own the BZC vault.

---

## B -- Cockpit honesty

### B1. EMC/FCS CONFIG can look dead -- KEEP

`ui/basalt/renderpolicy.lua` `sigFlight` has no `uiRev`. Region `onNav` only bumps `uiRev` (`pages/flight.lua:29-31`, `pages/emc.lua:18`). `Region:showTop()` runs only from `Region:apply`. `Region:changed()` exists and is **unused**.

Basalt `onClick` must not yield; it does not swap our lazy child frames. Screen swap waits for the 250 ms rate gate **and** a `sigFlight` change.

**When it still works:** engine pulsing (`pulses`/`feeding` in the sig), fuel poll (~3 s), FCS missing blink, or opening PARAMS (`paramsOpen` **is** in the sig).

**When it fails:** engine off, FCS idle, fuel stable -> CONFIG / CAL FUEL / BACK can sit until the next 3 s poll.

### B2. FCS SYNC labels stay `--` -- KEEP

BIT/CONFIG is event mode. `applyNow` only `showScreen`s. Other BIT pages call `region:apply(nil)` at the end of `build()`. `fcssync.build` seeds `SERVER: --` / `LINK: --` and never calls `apply()`. START/STOP bump `uiRev` and do not apply. START/STOP still hit `cfgserver`. Chrome never updates for the rest of the session.

### B3. POS HOLD / CLR DAMP live on the A/P page -- KEEP

Not autopilot. Commands send. `ap` is event-mode; `build()` does not `apply()`. Color never follows telemetry. Test the commands if that 1x1 monitor is assigned; the buttons will not show reported state.

### B4. WPT/RT/DTC look live with NAV down -- KEEP

`wptclient.lua` `C:stale()` exists and has **zero callers** (source + dist). `online` is only set `true`. Header comment claiming read-only when silent is false. Mutates are fire-and-forget.

### B5. TRK looks like a real mode chip -- DOWNGRADE (cosmetic)

Deferred by spec. Same red chip as inactive LDG/DRN, no `onClick`. Will confuse the test, will not fly the craft. A/P ALT HLD / WAYPOINT / RTB are honestly disabled.

### B6. Unassigned monitors stay blank -- accepted / not an issue

Unassigned monitors stay dark by operator choice (2026-08-31). `rootForMonitor` does default to `"emc"`, but `Monitors.resolve` puts present-but-unassigned names in `unassigned`, and `buildFrames` only builds `assigned`. The `pages/emc.lua` comment is wrong. SET UI is required if a picture is wanted; this is not a defect.

### B7. Gauge titles stay BZC / BDSL -- DOWNGRADE (leftover chrome)

LFED and CONFIG `FUEL:` **are** live. Titles are build-time `SOLID_ABBR` / `LIQUID_ABBR`. Wrong label, right gauges.

### B8. Two "CAL FUEL" actions -- DOWNGRADE (UX)

EMC = manual max + gfxpicker `fuel` command. UI CAL = one-shot `fuelReaders` poll. Both wired. Same name, different job.

---

## C -- Config / Suite

### C1. Suite `extendConfig` uses fused `hwconfig` on split files -- KEEP, refined

`fcs.io.config.withDefaults` is `hwconfig.merge`. Extra keys in saved tables **survive**. This **pollutes** `eh2_tuning.tbl` / `eh2_senscal.tbl` / `eh2_ui_config.tbl` with `thrusters`/`bindings`; it does **not** wipe `signPitch` / gains. Risk is dirty-on-disk + DTC/SYNC copies, not an instant cal wipe.

`eh2_fuelcal.tbl` is glob-PROTECTED but not in the Suite backup list.

### C2. `flight` launcher skips the boot loader -- KEEP

`launchers/fcs.lua` -> `loaderui.run()` then `tools.flight` (fused write). `launchers/flight.lua` is `require("tools.flight")` only -- last fused snapshot. Calibrate/MDB write **split**. Until you reboot via `fcs`, `flight` / `hovertest` fly stale fused.

### C3. Corrupt split: tools save defaults over the file -- KEEP

Boot UI treats `err` as CORRUPT. `binddevices` / `calibrate` / `probe` ignore `err`.

### C4. Classic Suite writes `/eh2_channel.txt` before install succeeds -- KEEP

`easyhover2_suite.lua` writes the marker before manifest fetch. Failed `--dev` leaves the PC on `dev`. SuiteX writes only after a successful Go/Repair.

### C5. Mid-run Suite drop -- DOWNGRADE (design)

Delete-then-write, stamp last, documented. Not a defect to fix before the test. Do not Ctrl-T a live install. `--fast` skips checksums.

### C6. CFG 105/106 stay open if boot aborts -- KEEP

`closeCfgChannels` only on successful `finish`. CC:T `ModemState` keeps channels until `close` / `closeAll`. `detach()` does **not** close them. Program end does not detach the computer from the modem. Next `fcs` still has 105/106 open. `commandTask` filters to 102 so commands are not applied; extra `modem_message` wakes on the FCS box.

---

## D -- NAV / GPS

### D1. Heading -- KEEP (stronger than first pass)

Dead NAV CFG (HDG SIGN / NAV TABLE / `headingMs`): confirmed unused. `navhdg` is gone. PFD uses FCS `compassHeading`.

**Craft-relevant:** calibrate writes **`signHeading` only** (`tools/calibrate.lua:44`). Display uses **`compassSign`** on **raw degrees** (`fcs/runtime/flight.lua:297-298`). Defaults both `1`. This craft's cal is `signHeading = -1`. `compassSign` stays `1` unless hand-set in fused bindings.

The **loop** is sign-corrected; the **PFD tape and NAV steering cue** (`navtarget.solve` uses `compassHeading`) can be mirrored vs the loop. In-world: yaw right and see if the tape agrees with the turn.

Simulated `navigation_table.getRelativeAngle` is not `mainThread`. This is our two-sign split, not a mod bug.

### D2. `minQuality` dummy; PFD treats any fix as OK -- KEEP

`thresholds.minQuality` is edited in NAV CFG and never read by `computeFix` / PFD / PARAMS. `gpsFixOk` = fix exists. PARAMS GPS SIG can show POOR while PFD still paints GPS ALT/TAS. GPS-y is the weak axis.

### D3. GPS / RELAY channel collision -- DOWNGRADE (footgun)

Defaults are disjoint (GPS 65000, relay 107, WPT 108/109, tel 101). CC:T channels 0-65535, max 128 open. **Only if you edit NAV CFG.** UI navfix listener is hardcoded 107.

### D4. HDOP uses all hosts, solver uses best quartet -- KEEP (honesty)

Solver is best-quartet (closed). Quality/HDOP still scores every host. A noisy 5th beacon can paint POOR while the fix is the good quartet.

### D5. Disk courier -- KEEP, not flight-critical

`rev` ignored (last write wins). Export not atomic. Import replies `wpt_store` not `wpt_disk_res` -> DTC import status can stay on last scan.

---

## E -- Resources / leftovers

| Item | Verdict |
|---|---|
| FCS fuel on control path | Clean. 1 Hz task. |
| `fcslog` off | Clean. |
| `paramsWatch` no TTL | SPEC (`No keep-alive, no timeout`). UI reboot can leave extras on the wire. Display still gated. Close PARAMS before rebooting UI. |
| Command `handled{}` | Sid-bounded. Fine for a test flight. |
| GPS `_beacons` never evicted | Filter-on-read. Fine unless junk IDs on 65000. |
| Unfiltered control `pullEvent` | Required for typewriter. Extra wakes do not `sensors()`. |
| FCS ack/health no pcall | Terminate still works (`bios.lua` `error("Terminated")` unwinds `waitForAny`). A non-Terminate throw kills that task -> shutdown. Tel path is `fault.orReraise`. |
| NAV/UI `pcall` around send | KEEP. Swallows `Terminated` in that coroutine. |
| Dist runner skips `test_theme` + `test_renderpolicy` | KEEP. In `tests/run_headless.sh`, absent from `tests/run_headless_dist.sh`. |
| `yawRear` mixer | Dead API. Harmless. |
| `docs/FCS_CORE_DESIGN.md` | Stale. LDG spec is boot default, not PRECISION. Do not fly from this file. |
| Glossary "PRECISION: default" | Stale vs `registry.default = "LDG"`. |
| `tests/test_flight_modes.lua` still fakes CPL as a flight mode | Leftover tests. Production `handleCommand` no-ops unknown ids. |
| `tools/hover_test.lua` sync CSV + no groundSense | True. Production path is `tools/flight.lua`. |
| `Region:changed()` unused | Supports B1. |

Server `computer_threads=1` / 10 ms tick: UI 3 s fuel `wrap` can stall the **UI PC** and share the world Lua budget. FCS is a different computer. Not an EH2 logic bug.

---

## Dropped from must-fix before test

- C5 Suite in-place install (design)
- D3 unless you edit NAV channels
- B5 / B7 / B8 as functional bugs
- `paramsWatch` TTL (spec)
- GitHub #10, A/P, TRK-as-mode, PROX, PFD Baro/GPS switch

---

## Already clean -- do not re-open

- Master vs flight split is in production (PRE/MAN/CRU/LDG/DRN + CPL/DCPL). PARAMS `FCS MODE` shows `PRE/CPL`.
- Command sid+id, retry cap 4, compact telemetry, FCS isolation if UI/NAV die.
- Best-quartet trilateration, beaconupdate timer leak, WPT DN clamp, deleted-route `routeActive`, store fan-out.
- Fuel table (8 fuels) matches picker and FCS scale.
- Drain-safety on bind/side (except live latch flip, A3).
- LFED + CONFIG `FUEL:` live.
- No optimistic FLIGHT mode chips (color from telemetry).
- Envelope sat forwarded through CRUISE/MAN/DRN. Oscillation deadband + auto-recover.

---

## Next (when we start fixing)

1. **A1** -- skip surge leash in CRUISE + reset setpoints on mode switch.
2. **B1** -- put `uiRev` on `sigFlight` (or `Region:apply` in `onNav`).
3. **A3** -- rebuild `engine.mode` + writer on `cycleMode`.
4. Then B2 apply-on-click, B3 A/P apply, B4 `stale()`, D1 `compassSign` from `signHeading`, C1 per-kind Suite merge.

Memory index: `C:\Users\m-kri\.grok\memory\eh2-checkpoints\eh2-feature-complete-sweep.md`
