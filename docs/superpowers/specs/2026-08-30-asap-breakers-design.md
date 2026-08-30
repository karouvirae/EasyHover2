# EasyHover 2 -- ASAP breakers (flight / UI / storage)

**Date:** 2026-08-30
**Status:** approved (user: fix ASAP items that can actually break flight, UI, or storage/memory; Superpowers SDD; merge+push main)
**Revert:** tag `pre-asap-fixes-2026-08-30` (`c2fd6ca`)
**Sweep:** `HANDOFF-feature-complete-sweep-2026-08-30.md`

## Goal

Fix the verified defects that can slam the craft, dump the fuel vault, wipe/pollute config, or leave a cockpit control dead. Not this pass: cosmetic TRK, gauge titles, two CAL FUELs, PARAMS TTL (spec), PROX/A/P/TRK-as-mode, GitHub #10, PFD Baro/GPS switch, NAV channel footguns, HDOP honesty, disk courier.

## Scope (priority order)

1. **A1 CRUISE slam** -- leaving CRUISE under CPL can rail surge (full reverse after detent).
2. **A3 latch/basic writer** -- in-session mode flip keeps the old writer; vault drain if hardware already changed.
3. **A4 noFuel vs chute** -- FCS disarms on empty Create tanks; UI still pulses the solid chute.
4. **B1 uiRev vs sigFlight** -- EMC/FCS region nav (CONFIG/CAL FUEL/BACK) does not wake the rate gate.
5. **C3 corrupt split overwrite** -- binddevices/calibrate/probe ignore `cfgspec.load` err and can save defaults over a broken file.
6. **C1 Suite fused extend** -- `extendConfig` runs `hwconfig.merge` on split + UI files.
7. **D1 compassSign** -- calibrate writes `signHeading` only; PFD uses `compassSign` (this craft `-1` vs `1`).
8. **C2 flight fused-only load** -- `tools/flight.lua` ignores live split until boot-loader rewrite.
9. **C4 channel marker** -- classic Suite writes `/eh2_channel.txt` before install succeeds.
10. **C6 CFG channels** -- abort/fail leaves 105/106 open (`ModemState` persists).

## Rules

- TDD. ASCII only in Lua strings/comments.
- No optimistic UI. No extra `getFuelAmountMb` / `getPower` / `peripheral.find` on the FCS control path.
- No extra modem channels. Control loop stays the authority.
- Dist + both manifests after source changes that ship (`node tools/build.mjs` then `bash tools/run_gen.sh`). Register new test files in **both** headless runners.
- User ship path: green tests + full-batch review -> merge to `main` + push. No PRs.
