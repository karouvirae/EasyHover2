# Handoff — EH2 Basalt Cockpit + Config Provenance (2026-08-10)

Resume doc for continuing the implementation in a fresh session/window/account. The SDD ledger
(`.superpowers/sdd/2026-08-10-eh2-cockpit-provenance/progress.md`) is git-ignored (local scratch),
so this committed file + `git log` are the durable recovery map.

## What this is

Building the EH2 UI-PC **Basalt 2.0 cockpit** + a **config-provenance system** (three per-concern
config files, an isolated FCS boot-phase loader, a UI-gated FCS SYNC responder, a DTC/disk courier).
The FCS flight-control stack is **frozen** (only boot-time reads/tooling touch the FCS).

- **Spec:** `docs/superpowers/specs/2026-08-10-eh2-cockpit-provenance-design.md` (read first)
- **Plan:** `docs/superpowers/plans/2026-08-10-eh2-cockpit-provenance.md` (28 tasks, 7 phases)
- **Execution:** superpowers **subagent-driven-development**, on branch **`main`** (EH2 convention:
  no worktree). Confirmed decision: **ship `release/basalt-full.lua` in the `ui` role** (T13/T27
  add it to the closure/manifest in `tools/gen_manifest.lua`).

## Progress so far (PHASE 1 COMPLETE — all review-clean)

| Task | Commit | Result |
|---|---|---|
| 1 — `fcs/io/tuningdefaults.lua` (checkpoint gains/caps/feel, shared source) | `4101667` | ✅ value-fidelity verified |
| 2 — `fcs/io/cfgspec.lua` (3-file schemas, merge, validate, load/save) | `5fa4174` | ✅ |
| 3 — `cfgspec.splitLegacy`/`assembleHw` (legacy migration round-trip) | `4bfd6ed` | ✅ no-config-lost proven |

State at handoff: `main` clean + pushed, **316 headless tests green**, manifest **IN SYNC**.
BASE for the next task = **`4bfd6ed`**.

## How to resume (next = Task 4)

1. Re-create the SDD workspace dir (ledger is gone in a fresh clone — rebuild from git):
   `bash <superpowers>/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-10-eh2-cockpit-provenance.md`
   then seed `progress.md` first line `# SDD ledger -- plan: docs/superpowers/plans/2026-08-10-eh2-cockpit-provenance.md` and record Tasks 1-3 done (commits above) so they are NOT re-dispatched.
2. Per task: record BASE (`git rev-parse HEAD`) → `scripts/task-brief PLAN N` → dispatch a fresh
   implementer subagent (see model tiers) → `scripts/review-package PLAN BASE HEAD` → dispatch a
   task reviewer → fix loop if needed → append completion + new BASE to the ledger.
3. **Gates every task:** `bash tools/run_gen.sh && bash tools/run_gen.sh --check` = IN SYNC, and
   `bash tests/run_headless.sh` fully green; new test files registered in the runner's `suites`.
   Commit + push `main`.

## Model tiers that worked this session

- **haiku** for tasks whose plan text contains the full code (transcription + testing) — Phase 1 all
  ran on haiku cleanly.
- **sonnet** for reviewers where correctness fidelity matters (value transcription, slicing, merge
  order, Basalt-API), and for the Task-9-style glue implementers.
- **opus** for the final whole-branch review.

## Next up

- **Phase 2 (T4-9):** `fcs/tuning.lua` reads `eh2_tuning.tbl` over defaults (T4); `tools/calibrate.lua`
  writes `eh2_senscal.tbl` + legacy read-through (T5); bare device-binding writer `tools/binddevices.lua`
  (T6); `fcs/comms/cfgsync.lua` protocol (T7); `fcs/boot/loader.lua` pure resolve/assemble (T8); the
  terminal boot UI + `launchers/fcs.lua` handoff (T9, glue + headless smoke).
- **Phase 3 (T10):** `ui/cfgserver.lua` gated responder.
- **Phases 4-7 (T11-28):** Basalt framework (cadence/nav/bootstrap/comms), pages, BIT/CONFIG hub +
  6 sub-menus (native SENS CAL/MDB + DTC + FCS SYNC), assembly, in-game smoke + screenshots.

## Watch-outs (from the spec/plan)

- **FCS-safe cadence** ([[feedback-ui-cadence-rules]]): the Basalt cockpit must be dirty-gated
  (state-model → quantized sig → diff-render); do NOT reintroduce the ~5Hz repaint storm that
  starved the FCS (fixed in `50d7708`). Task 11 builds the gate; Task 14 must honor it.
- **Basalt API:** verify every element/method against the vendored `release/basalt-full.lua`
  (pinned Pyroxenium/Basalt2 @ f6cde73), never from memory. Tests render ONE frame via
  `basalt.update("timer", -1)`, never `basalt.run()`. (SuiteX = `easyhover2_suitex.lua` is the
  proven reference for bootstrap/theming/schedule/multi-element patterns.)
- **Parity:** MDB-Conf (T22) and SENS CAL (T24) must write byte-identical files to the bare
  `tools/*` fallbacks — asserted by parity tests.
- **Migration:** boot loader "Own" sources read-through legacy `/eh2_hw_config.tbl` via
  `cfgspec.splitLegacy` when the split files are absent (so existing calibration survives).
