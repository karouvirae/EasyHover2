# Report -- ASAP breaker fixes (2026-08-30)

**Shipped:** `main` @ `84c80c3` (pushed)
**Before (revert):** tag `pre-asap-fixes-2026-08-30` = `c2fd6ca`
**After:** tag `post-asap-fixes-2026-08-30` = `84c80c3`
**Local zips (gitignored):** `backup/2026-08-30_pre_asap_fixes/` and `backup/2026-08-30_post_asap_fixes/`
**Gates:** source **1389/0**, dist **1357/0**, suite e2e **green** (11 phases)

Restore if something is wrong in-world:

```
git checkout pre-asap-fixes-2026-08-30
```

Suite install after you accept this ship:

```bash
wget run https://raw.githubusercontent.com/maar-10/EasyHover2/main/easyhover2_suite.lua
```

---

## What was in scope

Only items that can **break flight, UI, or storage/memory**. Cosmetic leftover (TRK chip, gauge titles, two CAL FUELs, PFD Baro/GPS switch, A/P, PROX, GitHub #10) was left alone.

## Fixes

### A1 -- CRUISE slam (flight)

**Symptom:** Leaving CRUISE under default CPL after a W-release detent railed surge reverse (full frontal brake). Spec said leaving CRUISE zeros the held surge; code only zeroed throttle.

**Fix:**
- `Pilot:update` skips the surge leash when `policy.surge == "throttle"` and keeps `surgePos` on measured.
- `flightMode` command calls `pilot:reset(_lastMeas)` after setMode (skipped at boot when `_lastMeas` is nil).

**Tests:** `tests/test_pilot_modes.lua`, `tests/test_flight_modes.lua`

**In-world:** CRUISE, hold W, release (detent), tap PRE. Should not slam reverse.

### A3 -- latch/basic writer (vault)

**Symptom:** UI CAL mode flip did not rebuild the live engine writer. Hardware vs live machine could leave the chute open.

**Fix:** `Engine:applyConfig` updates `mode` only on a real change. Entering latch rebuilds the writer then `blockNow`. Leaving latch: drop FEED if raised, hold BLOCK for `LATCH_LINE_MS` (150 ms) via `tick` (no `sleep` in onClick), then rebuild to basic. Failed BLOCK raise does not stick pending. Second MODE click while leaving is a no-op.

**Tests:** `tests/test_ui_engine.lua`, `tests/test_bitconfig_uical.lua`

**In-world:** Flip latch in UI CAL, wait ~0.2 s before expecting the new writer. Reboot still the safest after a hardware change; the in-session path is now real.

### A4 -- noFuel vs chute (vault)

**Symptom:** FCS disarmed on empty Create tanks; UI still pulsed the solid chute.

**Fix:** `Engine:applyTel({noFuel=true})` forces master off. Engine tick calls it. ENG SW refuses toggle-on while `noFuel`.

**Tests:** `tests/test_ui_engine.lua`, `tests/test_region_emc.lua`

### B1 -- CONFIG looked dead (UI)

**Symptom:** EMC/FCS region nav (CONFIG / CAL FUEL / BACK) only bumped `uiRev`, which was not in `sigFlight`. Idle ship: drilldown waited for the 3 s fuel poll.

**Fix:** `sigFlight` always includes `uiRev`.

**Tests:** `tests/test_renderpolicy.lua`

### C3 -- corrupt split overwrite (storage)

**Symptom:** binddevices / calibrate / probe ignored `cfgspec.load` err and could save defaults over a broken file.

**Fix:** loaders return `nil, err` on unparseable; `run()` prints and aborts without save.

**Tests:** `tests/test_binddevices.lua`, `test_calibrate.lua`, `test_probe.lua`

### C1 -- Suite fused extend (storage)

**Symptom:** `extendConfig` ran `hwconfig.merge` on split + UI files, injecting `thrusters` into `eh2_tuning.tbl`.

**Fix:** `fcs.io.config.withDefaults(cfg, path)` merges by basename kind (`devbind`/`senscal`/`tuning`/`fuelcal`/`ui`/`fused`). Suite passes `path`.

**Tests:** `tests/test_suite.lua`

### D1 -- compassSign vs signHeading (flight/UI)

**Symptom:** Heading cal wrote `signHeading` only. PFD uses `compassSign` (this craft `-1` vs `1`). Tape could disagree with the loop.

**Fix:** `applyHeading` sets `compassSign = result.sign` next to `signHeading`. Control `headingScale` unchanged.

**Tests:** `tests/test_calibrate.lua`

**In-world:** Re-run heading cal (or set `compassSign` to match `signHeading` in senscal), then yaw and check the PFD tape.

### C2 -- flight fused-only load (flight)

**Symptom:** `flight` launcher skipped the boot loader, so split cal from MDB/calibrate was ignored until `fcs` boot rewrote fused.

**Fix:** `cfgspec.tryAssemble` + `tools/flight.lua` prefers split files when present.

**Tests:** `tests/test_cfgspec.lua`

### C4 -- channel marker (storage)

**Symptom:** Classic Suite wrote `/eh2_channel.txt` before the manifest fetch. Failed `--dev` flipped the PC to `dev`.

**Fix:** Persist only after a **successful install** (`performPlan` / dashboard Go). `--check`/`--list`/failed fetch/role abort/`current` no-op do not write.

**Tests:** `tests/test_suite.lua` + e2e `--check --dev did not persist a channel switch`

### C6 -- CFG 105/106 leak (wakes)

**Symptom:** Boot abort left modem channels open (`ModemState` persists across programs).

**Fix:** `closeCfgChannels` on abort, failed resolve, and successful finish.

**Tests:** `tests/test_bootloaderui.lua`

---

## Not changed (intentionally)

TRK placeholder look, gauge title BZC/BDSL, two CAL FUEL names, A/P page apply, WPT offline gate, unassigned monitors, PARAMS watch TTL, PROX, PFD ALT/SPD source, GitHub #10, dist skip of `test_renderpolicy`.

---

## Rulings made during SDD

1. Leave-latch must not `sleep()` in Basalt onClick; rebuild is deferred `LATCH_LINE_MS` via `tick`.
2. `applyConfig` only clears latch line timers when mode actually changes (latch spec > Task 2 first draft).
3. T7-T9 implemented in the controller session after two hung implementers; still TDD + tests.
4. Final-review C4 remaining window (write after manifest, before install) was closed before merge.

---

## In-world smoke for tomorrow

1. Boot LDG + CPL (unchanged).
2. CRUISE, W hold, release, tap PRE -- no reverse slam.
3. UI CAL latch flip -- wait a beat; chute still blocked when master off.
4. Empty Create tanks -- ENG SW should not stay ON / chute should stop.
5. EMC CONFIG with engines idle -- should open immediately.
6. Yaw vs PFD tape after heading cal (or after matching `compassSign`).
7. `flight` after MDB/calibrate without a full `fcs` boot should pick up split files.

```bash
wget run https://raw.githubusercontent.com/maar-10/EasyHover2/main/easyhover2_suite.lua
```
