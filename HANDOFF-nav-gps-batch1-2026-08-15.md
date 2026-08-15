# HANDOFF — NAV+A/P Batch 1 (broadcast GPS) — 2026-08-15

Resume point for a fresh session (other account). Everything below is committed except where noted.

## Session-start setup (do these first)
- Invoke skills: `superpowers:using-superpowers` (auto), `dev-permissions` (grant both: CraftOS-PC
  self-test + self-hosted Firecrawl), `minecraft-mod-docs`. Standing dev permissions are
  per-conversation — re-grant.
- Repo: `C:\Users\m-kri\Claude Code\EasyHover2`. Target MC 1.21.1, CC:Tweaked + Basalt 2.0 full build.
- Memory: `nav-ap-batch1-checkpoint` (in `MEMORY.md`). Design spec (committed):
  `docs/superpowers/specs/2026-08-15-eh2-nav-gps-batch1-design.md`. Detailed plan:
  `C:\Users\m-kri\.claude\plans\bright-crunching-turing.md`.

## Where we are
- Branch **`nav-gps-batch1`** (off `main`). Commits so far:
  - `ef21cfe` docs(spec): NAV+A/P Batch 1 design
  - `e2cf394` feat(nav): T1 part 1 — `nav/lib/trilaterate.lua` + `nav/lib/geometry.lua` (TDD, 752/0)
- `main` is at `9c48382`, pushed, in sync. It has two shipped fixes this session:
  - `dd3800e` SuiteX re-entrant-startCheck freeze fix (wget-run, **no in-game update needed**).
  - `9c48382` UI-role relay hardening (honest ENG SW via `isRelayReady`; `ui/relaywriter.lua`
    releases the abandoned relay side). **This touches the installed `ui` role → user must update the
    UI PC in-game via the Suite.** FCS untouched.
- Gates all green when paused: source suite **752/0**. (dist suite + e2e unaffected — nav modules
  aren't shipped yet.)

## The task: NAV+A/P Batch 1 — broadcast GPS + two new roles
Passive **broadcast** GPS (NOT EH1's request-based `gps.locate()`): beacons periodically transmit
`{id,x,y,z}` on a UI-configurable channel over **ender modems**; the NAV pc trilaterates from the CC
`distance` field on each `modem_message`. Broadcast doubles as the beacon mesh. New Suite roles:
**nav** (advanced pc, Basalt 2 UI) and **beacon** (basic computers, keyboard `term` UI). Batch 1
touches ZERO existing flight code. **Hard FCS-safety rules:** beacons event-driven + sleep between
broadcasts (never busy-wait); interval configurable, 1 Hz default floor; reception/trilateration
only on NAV; **FCS never opens the GPS channel**.

## Remaining tasks (TDD each; plan file has full detail)
- **T1 (finish):** `nav/lib/heading.lua` (navtable `getRelativeAngle` → absolute heading 0..360 +
  compass label + sign calibration) and `nav/lib/fix.lua` (`make(pos,{age,source,nBeacons,quality})`).
- **T2:** `nav/comms/gpsproto.lua` (encode/decode `{id,x,y,z,seq}`, reuse `fcs/comms/protocol.lua`)
  + `nav/comms/receiver.lua` (aggregate `modem_message (ch,_,msg,dist)` → `{[id]={pos,dist,age}}`).
- **T3:** `beacon/config.lua` + `beacon/runtime.lua` (broadcast loop; hear peers; self-check =
  measured dist vs `|selfPos-peerPos|` → MISMATCH; grade via `nav/lib/geometry`).
- **T4:** `beacon/console.lua` (keyboard term UI, monochrome-safe, EH1 beacon-screen shape) +
  `launchers/beacon.lua`.
- **T5:** `nav/config.lua` + `nav/runtime.lua` (receiver → trilaterate → fix; navtable → heading;
  relay fix/heading to craft wired net via `fcs/comms/modem`).
- **T6:** `nav/app.lua` (mirror `ui/basalt/app.lua` bootstrap/loops/`ensureBasalt`) + `nav/ui/*`
  (MAIN + CONFIG tabs, drilldowns) reusing `ui/basalt/{region,picker,switchbtn,nav}` + `launchers/nav.lua`.
- **T7:** add `nav` + `beacon` to `ROLES` in `tools/gen_manifest.lua` (nav ships `basalt-full.lua`
  via `extraFiles` like `ui`; beacon does not). `node tools/build.mjs` → `bash tools/run_gen.sh` →
  `--check` IN SYNC. Register the nav/beacon test files in the **dist** suite list now (they ship).
  Add nav/beacon e2e phases. Full gates.
- **T8:** whole-branch review → merge+push. In-game: 4 beacons + NAV via `wget run` Suite role picker.

## Reuse map (don't reinvent)
Role wiring: `tools/gen_manifest.lua` ROLES + `tools/closure.lua` + `launchers/*`. Comms:
`fcs/comms/protocol.lua`, `fcs/comms/modem.lua`. Config: `ui/config.lua` / `fcs/io/config.lua` +
`fcs/io/cfgspec.lua`. NAV UI: `ui/basalt/app.lua`, `ui/basalt/region.lua`, `ui/basalt/nav.lua`,
`ui/basalt/picker.lua`, `ui/basalt/switchbtn.lua`, bitconfig drilldown pattern. EH1 reference:
`../EasyHover/gps_beacon/lib/geometry.lua` (already ported), `../EasyHover/docs/{GPS,NAVIGATION}.md`.

## Test/gate mechanics (learned this session)
- `tests/run_headless.sh` now stages `nav/` and `beacon/` into the CraftOS sandbox (added). New
  test files go in the source suite list; add to the **dist** suite list only once the module ships
  in a role (T7), else the dist run can't find it.
- Headless run: `bash tests/run_headless.sh` (source), `bash tests/run_headless_dist.sh` (dist),
  `bash tests/run_suite_e2e.sh` (11 phases). Build: `node tools/build.mjs`; regen: `bash
  tools/run_gen.sh` (+ `--check`). New tests must be registered in the suite list(s).
- Ship flow (established): TDD → gates → whole-branch review (inline is fine) → ff-merge to main →
  `git push origin main`. Commit footers: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  and the `Claude-Session:` line.

## Workflow note
User asked to **pause after every subtask** to manage usage. Honor that. Auto mode approved.
Phase 2 (waypoints/routes/AP modes HOLD/GOTO/RTB/AUTOLAND/NAV map, FCS consuming the fix) is a
LATER brainstorm — out of Batch 1.
