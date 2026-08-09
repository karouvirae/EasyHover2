# EasyHover 2 SuiteX — Basalt 2.0 Suite front-end — design

- **Date:** 2026-08-09
- **Status:** approved (brainstormed + cleared with the user)
- **Scope:** ONE new run-via-`wget` program, `easyhover2_suitex.lua`, plus a small set of pure
  support modules and a vendored Basalt. The classic `easyhover2_suite.lua` is left byte-for-byte
  untouched. This is the first Basalt 2.0 port and the agreed proof-of-concept for the wider UI swap.

## Goal

Port the Suite's operator UI to **Basalt 2.0 (full build only)** to gain tabs, dropdowns, themes and
richer widgets — and to agree on Basalt's responsiveness/smoothness/design before porting the UI-PC
panels. SuiteX must do everything the classic Suite does (detect role, check integrity, install /
update / repair / switch, launch diagnostics) by **reusing the classic Suite's engine unchanged**.

## Coexistence (two Suites)

- `easyhover2_suite.lua` — the current pure-CC Suite. **Unchanged.** The dependency-free,
  always-works installer; also the only option on a basic (non-color) terminal.
- `easyhover2_suitex.lua` — NEW. The Basalt front-end. Requires a color/advanced terminal; on a
  basic terminal it prints a one-line "use the classic Suite" notice and exits.
- Both are maintained going forward. The future full custom-UI (non-Basalt) EH2 variant, and whether
  the classic Suite is later brought up to SuiteX's feature/visual level, are **out of scope** here
  (decided after the user screenshots SuiteX).

## Bootstrap (SuiteX run sequence)

1. **Terminal gate.** If `term.isColour()` is false → print "SuiteX needs an advanced terminal; run
   the classic `easyhover2_suite.lua` instead." and return.
2. **Ensure Basalt.** `basalt-full.lua` is **vendored in the repo** (pinned commit per
   [[feedback-basalt-full-build]]). SuiteX ensures a local copy: if missing or its checksum ≠ the
   manifest's, fetch it (cache-busted, like every Suite fetch) and checksum-verify before use, then
   cache to disk (`/basalt-full.lua`). Load it. A failed/again-corrupt fetch aborts with a clear
   message (never run a half-downloaded Basalt).
3. **Load the shared engine.** Fetch the classic `easyhover2_suite.lua`, `load()` it with
   `_G.EH2_SUITE_NO_RUN = true` so it returns the `Suite` engine table **without running an install**.
   (Both Basalt and the engine are fetched fresh + cached each run, so both stay current.)

## Engine reuse

SuiteX owns **no install/verify/repair logic of its own** — it calls the classic engine:
`Suite.detectRole`, `Suite.integrity`, `Suite.choosePlan`, `Suite.performPlan`, `Suite.backupConfig`,
`Suite.diffLabel`, `Suite.statusColour`, `Suite.diagTools`, plus manifest fetch + state read.

- Any helper SuiteX needs that is currently a file-local in the classic Suite (e.g. `fetch`,
  `readFile`, manifest load, state load) is exposed on the `Suite` table as an **additive,
  behavior-preserving** change (new table fields only; no logic or output change to the classic run).
- `Suite.performPlan` currently prints progress to the terminal. Add an **optional progress callback**
  (default = the existing print, so classic behavior is identical) so SuiteX can route progress lines
  into a Basalt log widget instead of raw `term` writes.

## Screens (Basalt, tabbed)

- **Main menu** — shown IMMEDIATELY on boot, regardless of install state, and NEVER blocks on the
  check. Contains: the EH2 logo, a **light/dark theme toggle**, a **status/findings** area that fills
  in as the check completes, and the **action buttons**.
- **Status/findings area** — populated by the async check (below): role, installed version, release
  version, plan (install/update/repair/current), and counts (ok / missing / outdated|corrupt — label
  via `Suite.diffLabel(plan)`), all colour-coded.
- **Action buttons** (enabled + coloured by the computed plan): **Go** (runs `performPlan` for the
  plan), **Verify** (re-run the check), **Repair**, **Switch role** (role dropdown), **Launch tool**
  (dropdown of `Suite.diagTools`), **Quit**. Each calls the shared engine; progress streams into a
  log widget; on completion the check re-runs so the findings reflect the new state.
- **Advanced tab(s)** — present but **placeholder** this cycle (future: per-install-version options
  such as a non-Basalt variant, `--fast`, manifest source override, etc.).

## Async integrity check (the resource care-point)

The integrity check checksums hundreds of KB and would freeze a Basalt frame if run synchronously.

- Drive it **incrementally**: a pure `checkDriver` steps the file list in small batches, returning
  `{ done, total, report }` each step, so the caller can update a progress bar and yield between
  batches. (Wrap/extend `Suite.integrity` to support stepwise progress without changing its result.)
- Run it as a **Basalt background task/timer** so the menu stays responsive; update a progress widget
  each step; render the findings + enable buttons on completion.
- This incremental-yield pattern is the template we reuse for the heavier UI-PC panels next.

## Theming

- A pure `theme` module: two palettes (`light`, `dark`), each an explicit map of semantic roles →
  colours, both verified for contrast. Toggle re-applies live.
- Semantics (carried from the classic Suite): green = current/ok, yellow = update/outdated,
  orange = repair/corrupt, red = error, cyan = install, plus panel/background/text/border/accent.

## Logo

A blocky/ASCII "EasyHover 2" wordmark (CC font is ASCII-only per [[reference-cct-font-ascii]]),
drawn with Basalt colour blocks. Exact look refined at implementation; the user will screenshot and
give visual confirmation before it's final.

## Vendoring + manifest

- Commit the pinned Basalt full build into the repo at `release/basalt-full.lua` (matching Basalt's
  own path convention).
- Add a **manifest entry** recording basalt-full's size+sum so SuiteX can verify its fetch with the
  same trust root (pinned HTTPS raw) the Suite already uses. `tools/gen_manifest.lua` learns to
  include it. SuiteX itself is fetched by the user's `wget run`; no self-update dance (matching the
  classic Suite's `selfIsPersistent` reasoning — a transient `wget run` has no saved self).

## Testing

- **Pure, headless-tested:** theme palettes (roles present in both; contrast sanity), the
  plan→button-state/colour map, the incremental `checkDriver` (steps to completion, report matches a
  one-shot `Suite.integrity`), and the engine-locals exposure.
- **Basalt rendering:** single-frame render via `basalt.update("timer", -1)` (never `run()`), then
  read the frame; plus in-game smoke + user screenshots.
- **Shared engine:** already covered by `tests/test_suite.lua`; the additive exposure/callback keep
  those green.
- Manifest sync guard (`tools/run_gen.sh --check`) continues to gate every run.

## Non-goals (this cycle)

- Real advanced-tab options; the UI-PC panels (EMC/FCS/NAV/AP/config) and the FCS tuning menu; the
  full non-Basalt custom-UI EH2 variant; any change to classic-Suite behavior or output.

## Open items (post-screenshot, not blocking)

- Final logo/main-menu look (user confirms via screenshot).
- Decision on the non-Basalt Suite's future (keep as-is vs. bring up to SuiteX's feature/visual level
  in a custom UI).
