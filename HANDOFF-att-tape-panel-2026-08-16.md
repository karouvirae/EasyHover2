# HANDOFF — NAV att/tape panel (PFD) design + GPS hotfix verify — 2026-08-16

Resume point for a fresh session (other account / any clone). `main` is pushed and current.

## Session-start setup (do these first)
- Invoke skills: `superpowers:using-superpowers` (auto), **`dev-permissions`** (re-grant both:
  CraftOS-PC self-test + self-hosted Firecrawl — per-conversation), **`minecraft-mod-docs`**.
  Standing dev grant: user OKs starting **WSL + Docker** to bring the Firecrawl stack up; **do NOT
  start Ollama** (leave `firecrawl_extract` / `formats:["json"]` alone).
- Load memories: **`nav-ui-pfd-brainstorm`** (THE design), `project-easyhover2`,
  `nav-ap-batch1-checkpoint`, `feedback-ui-cadence-rules`, `reference-cct-font-ascii`,
  `feedback-basalt-full-build`, `reference-simulated-propulsion-cc-api`,
  `feedback-usage-budget-handoff` (this pause-and-handoff workflow).
- Repo: `C:\Users\m-kri\Claude Code\EasyHover2`. MC 1.21.1, CC:Tweaked + Basalt 2.0 FULL build.
- `main` HEAD `c0777df` (nav GPS hotfix). NAV Batch 1 shipped + merged (roles nav + beacon live).

## Where we are — two threads

### Thread 1 — GPS/NAV hotfix: SHIPPED, awaiting in-game confirmation (USER's task)
`c0777df fix(nav): bind navtable by auto-detect (heading) + GDOP-honest quality` — on `main`.
- **Heading bug** (was `--- --`): root cause = NAV never bound the navigation_table (no auto-detect,
  no config setter). Fixed: `nav/app.lua:buildRuntime` now auto-detects `navigation_table` (then a
  `getRelativeAngle`-capable fallback).
- **Position off ~11 blocks while q read 1.00**: NOT a solver bug (solver is exact for exact
  distances — proven). Root cause = **GDOP**: 4 beacons clustered ~130×140 and ~800 blocks away in
  one direction → a ±0.5-block distance error amplifies to 5–19 blocks. Fix (software honesty):
  quality is now **GDOP-aware** — `geometry.pdop(hosts,atPos)` + `geometry.dopQuality` → the NAV
  reads `POOR 4 of 4 ~6 blk` for that constellation instead of a lying `USABLE q 1.00`; a properly
  surrounding set reads `GOOD ~2 blk`.
- **USER is doing (in-world):** (1) update the **NAV PC** via `wget run .../easyhover2_suite.lua`
  (only the NAV role NEEDS it) → verify heading now populates (auto-detect); (2) **redeploy the 4
  beacons on their own chunkloaders spread over ~6k blocks** to surround the operating area (wide
  baseline + height spread) → NAV quality should climb to GOOD and the position converge. Expect a
  ~1–2 block floor from CC's sub-block distance rounding even with perfect geometry.
- **If heading is STILL `--- --` after the NAV update:** the navtable's `getRelativeAngle()` is
  returning nil at the mod level (not locking onto the magnet) — probe the peripheral directly next.

### Thread 2 — NAV att/tape panel (PFD): DESIGN COMPLETE, spec written. NEXT = plan + build.
Brainstorm finished and approved ("looks good"). **Spec committed:**
`docs/superpowers/specs/2026-08-16-eh2-att-tape-panel-design.md`. Full details there; the load-bearing
decisions:
- A **dedicated UI-role cockpit page** = **heading tape** (top) + **FPM-style attitude indicator**
  (fixed subpixel-dashed horizon at mid-height; hollow circle + tilting wings = craft; pitch=vertical
  translate, bank=cell-stepped wing rotation) + **ALT** + **SPD** readouts (lower-right). ALL FOUR
  share **one Basalt frame / one `apply()` / one redraw**, on the existing **dirty-gate** — **no
  fixed-rate timer** (update like current panels; quantization granularity is the load lever).
- **Data:** attitude(pitch/roll) + SAS(surge) = **UI reads gimbal + surge sensors LOCALLY** in a
  scheduled poll loop OFF the render path (non-mainThread → cheap). heading + baroAlt = **existing FCS
  telemetry (NO flight.lua change)**. gpsAlt + TAS = **NAV relay ch 107** (NAV just adds ground speed;
  gpsAlt = fix.y). GPS sources show only on a good fresh fix, else `---`. Display default this batch =
  **Baro + SAS**; the ALT/SPD display-source switch ships with the later NAV-page batch.
- **`SENS SOURCE` submenu (UI BIT/CONFIG hub):** attitude/surge calibration source is switchable
  between **`FCS`** (fetch the FCS's cal via cfgsync/disk + apply) and **`SELF`** (the UI's own tiny
  level+tilt cal). **BOTH built; the unselected one is fully no-op.** (User rejected the simpler
  "FCS telemeters it" option 1 to keep flight.lua untouched.)
- **FCS untouched. NAV: relay `+= groundSpeed` only.**
- **PREREQUISITE (user to confirm in-world):** gimbal + surge sensors must be on the shared wired net
  reachable by the UI PC (not FCS-adjacent-only), or the UI can't wrap them.

**Build decomposition (seam = an instrument-state contract `{pitch,roll,heading,baroAlt,gpsAlt,sas,
tas,altSource,spdSource,gpsFixOk}`):**
- **Batch A — the panel** (visible, fully unit-testable against a MOCK state; view-models + Basalt
  render probes; subpixel-horizon helper + ASCII fallback; zero sensor/cal work). **Do this first.**
- **Batch B — data + calibration** (gimbal/surge poll loop + both cal sources + SENS SOURCE +
  self-cal + FCS-cal fetch + ch-107 listener + NAV groundspeed + cadence-sig additions).

**RESUME action:** run **`superpowers:writing-plans`** against the spec for **Batch A**, then
TDD-implement on a branch. Tape visual defaults (~2–3°/cell, tick/10, label/30, cardinal letters,
fixed `^` lubber, cell-granular interpolated scroll) are proposed in the spec and adjustable during A.

## Ship mechanics (established, unchanged)
- TDD each task (watch RED → GREEN). Gates: `bash tests/run_headless.sh` (source) +
  `bash tests/run_headless_dist.sh` (minified dist) + `bash tests/run_suite_e2e.sh` (13 phases);
  build = `node tools/build.mjs`; regen = `bash tools/run_gen.sh` (+ `--check` IN SYNC). New test
  files → source suite list now; add to the **dist** list + stage the dir only once the module ships
  in a role. New UI page files ride the existing `ui` role closure (no new role).
- Ship flow: TDD → gates → whole-branch review → ff-merge to main → `git push origin main`. Commit
  footer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- CraftOS headless self-test pattern + Basalt render probe (`basalt.update("timer",-1)`, NEVER
  `basalt.run()` in tests) per `reference-craftos-headless-testing`.

## Workflow note
User manages usage in 5h windows; **pause after every subtask** and ask, or hand off (this file).
We stopped here because the window closed mid-brainstorm-wrap (design done, spec written, plan not yet
started). Auto mode approved. Great session. 🛩️
