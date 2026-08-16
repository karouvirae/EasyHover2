# EH2 Config UX Tweaks — Approved Design (2026-08-16)

**Status: APPROVED by the user (2026-08-16). Design is LOCKED — do not re-brainstorm.**
Three independent UI/tool features in the EH2 config area. None touch frozen flight code
(`fcs/**` flight/kernel); the one FCS-side piece is a STANDALONE console tool, not the flight app.

Repo: `C:\Users\m-kri\Claude Code\EasyHover2`. Base: `main` (was `e8c5862` at design time — the two
SuiteX post-ship fixes: clickable Advanced-tab checkboxes + Repair-installs-optional-tools).

Reference style for all UI work: the overhauled menus `ui/basalt/bitconfig/senscal.lua` /
`senssource.lua` (region drilldowns + `configkit.actionRow`) and `pfd.lua`.

---

## Approved decisions (from brainstorming)
1. **Import transport = shared networked disk.** The FCS and UI PC share a networked disk (both mount
   the same physical disk). The FCS dumps its 3 configs to the disk; the UI imports them.
2. **Disk CLEAN scope = only foreign/invalid files.** Delete anything that is NOT a valid EH2 config
   (foreign files + corrupt `eh2_*.tbl`); keep valid EH2 configs. Show the list + confirm.
3. **Button style = glyphs for compact/nav actions + full words for primary actions, multi-row.**
4. **GLYPH CAVEAT (important):** CC:Tweaked's font does NOT reliably render `⟳`/`✓`/`✕`. Use
   CC-native characters where they exist (e.g. `"\27"` = ← for back, `"\26"` = → , `"\24"`/`"\25"` =
   ↑/↓). For any action lacking a safe native glyph (rescan/refresh/confirm/cancel), make the glyph a
   NAMED CONSTANT the user confirms in-game (same pattern as the PFD horizon glyph in
   `ui/basalt/instruments/horizon.lua` `STYLE.subpixel`), with a short-word fallback (`OK`, `RE-SCAN`,
   `CANCEL`). When in doubt, prefer a short full word over an unrenderable glyph.

---

## Feature 1 — Readable multi-row buttons (MDB-Conf + DTC)

**Root cause:** `ui/basalt/configkit.lua` `M.actionRow` calls `M.splitWidths(pos.w, #specs)` — it
divides one row's width EVENLY across every button, so 3+ buttons on a narrow monitor each get
`fitLabel`-truncated (→ "SAVE ^CAN^ACK" in MDB). Both MDB and DTC over-pack a single row.

**Approach:** stop cramming. Lay buttons across MULTIPLE `actionRow` calls (1–2 buttons per row) so
primary actions keep full words with enough width; compact nav actions become single-glyph buttons.
Do NOT rewrite `actionRow` itself — reuse it, just call it per-row. (If a small helper reduces
repetition, e.g. a stacked-rows convenience in `configkit`, that's fine, but not required.)

- **MDB-Conf overview footer** (`ui/basalt/bitconfig/mdb.lua`, currently ~line 267:
  `actionRow{ SAVE, RESCAN, < BACK }`): split into `SAVE` (full-width row) then a row of
  `⟳`(rescan) + `←`(back) glyph buttons. The 5 group buttons above stay as-is.
- **DTC top screen** (`ui/basalt/bitconfig/dtc.lua` `M.build`, currently `EXPORT/IMPORT/REFRESH` one
  row): `EXPORT` / `IMPORT` (2-up, full words) → `REFRESH`(⟳) + `SCAN` row → `←` back. This screen
  also gains `IMPORT ALL` (Feature 2) and `SCAN` (Feature 3) — lay them across rows so nothing
  truncates; mind small-monitor height (header + summary + ~4–6 action rows).
- **DTC confirm screens:** `✓`/`✕` glyph buttons (or `OK`/`←` fallback per the glyph caveat).
- Inner drilldown/group screens already use a single `<` — leave them.

**Testing:** existing construction-probe tests (`test_bitconfig_dtc.lua`, `test_bitconfig_mdb.lua`)
must stay green; update the ones that assert the old flat footer element shape. Prefer asserting the
new rows via `region.built.<id>.handle.elements` (as the DTC Task-12 tests do). Keep any pure
label/glyph choice in a NAMED constant so a test can pin it and the user can flip it after in-game
confirmation.

---

## Feature 2 — Import all 3 FCS configs to the UI (via shared disk)

**Goal (user is "lazy"):** get the FCS's 3 correct configs (`eh2_devbind`, `eh2_senscal`,
`eh2_tuning`) onto the UI PC in ~one action, via the shared networked disk.

**Two pieces:**
1. **New FCS-side console tool** (STANDALONE, installed via SuiteX like `splitconfig`/`beaconupdate`
   — NOT a flight-app change): reads the FCS's 3 local split config files and writes them to the
   networked disk. Suggested name `fcs2disk` / `dumpconfig` (pick in the spec). Find the disk drive
   (`peripheral.find("drive")` + `getMountPath`), write each existing `cfgspec.FILES[kind]` to
   `<mount>/<cfgspec.FILES[kind]>`. Pure core (`M.plan`/`M.run` with injected deps) + launcher, TDD'd
   like `tools/splitconfig.lua`. Filenames from `fcs/io/cfgspec.lua` `FILES` — never hardcode.
   - Wire into SuiteX Advanced tab: new `SuiteX.checkboxLabels("...")` checkbox +
     `SuiteX.toolsToInstall` flag + `installToolIfRequested`/`installOneTool` doneMsg/displayName
     maps + a manifest `tools` entry (`tools/gen_manifest.lua buildTool`) + register any new
     `tests/test_*` in `tests/run_headless_dist.sh`.
2. **UI DTC `IMPORT ALL` action** (`ui/basalt/bitconfig/dtc.lua`): imports EVERY valid kind present
   on the disk → UI-local in one shot, backup-before-import each (reuse `M._importKind`), with ONE
   confirm. Add a pure helper (e.g. `M._importAll(mount, deps) -> {imported=[…], skipped=[…]}`) that
   loops `M.KINDS`, importing only kinds where `M._scanKind(...).diskHas and .diskValid`. TDD with the
   in-memory `deps` store the existing DTC tests use.

**Flow:** run the FCS tool on the FCS console → 3 configs land on the shared disk → UI DTC →
`IMPORT ALL`. (uicfg is UI-only and NOT on the FCS — import covers the 3 FCS kinds; `IMPORT ALL`
simply imports whatever valid kinds are on the disk.)

---

## Feature 3 — DTC disk scan + clean

**Goal:** detect a disk that has foreign/other data but no clean EH2 config, and let the user wipe
the junk (keeping any valid EH2 config) before using the disk.

- **New DTC `SCAN` action:** list every file on the disk mount and classify each:
  - **valid** — filename ∈ `M.FILE`/`cfgspec.FILES` AND body unserialises + passes `M.validateKind`;
  - **invalid** — an `eh2_*.tbl` (EH2-named) that is missing/corrupt/fails validation;
  - **foreign** — any other file.
  Surface a summary (e.g. "valid N · foreign M · invalid K"); if there is **no valid EH2 config but
  foreign/invalid data present**, flag that the disk should be cleaned.
- **`CLEAN` action:** deletes ONLY foreign + invalid files (keeps valid EH2 configs), shows the list
  of what will be deleted, and requires a **confirm** (reuse the DTC per-row confirm-screen pattern).

**Design seams (pure, TDD'd with injected deps):**
- `M._scanDisk(mount, deps) -> { valid={kinds…}, foreign={paths…}, invalid={paths…} }` — needs a new
  `deps.list` (default `fs.list`), plus existing `deps.exists/read`. Classify via `M.FILE` reverse
  lookup + `M.validateKind(kind, textutils.unserialise(read))`.
- `M._cleanDisk(mount, deps) -> {deleted=[…]}` — deletes the foreign+invalid set via `deps.delete`.
- Extend `resolveDeps` with a `list` default (`fs.list`), mirroring how `attributes`/`backup` were
  added in the config-overhaul batch.

---

## Constraints & ship mechanics
- **No frozen flight-code changes.** The FCS import tool is a standalone console program (like
  `splitconfig`). All other work is UI (`ui/basalt/**`), the SuiteX installer, and the config tools.
- **Manifest/dist:** the new FCS tool is a manifest `tools` entry → it IS in the dist closure, so a
  final T14-style build is needed (`node tools/build.mjs && bash tools/run_gen.sh`, register new
  `tests/test_*` in `run_headless_dist.sh`, commit `dist`/`manifest*.lua`). Per-task: commit SOURCE +
  tests only, leave manifest/dist dirty, one authoritative build+commit at the end. NOTE:
  `easyhover2_suitex.lua` itself is NOT in the closure (standalone `wget run`), but the tool's
  manifest entry + dist files ARE.
- **TDD every task** (pure seams first, RED before editing a manifested impl file — the sync-guard is
  clean while only tests change), gates (`bash tests/run_headless.sh` + `run_headless_dist.sh` +
  `run_suite_e2e.sh`), whole-branch review (opus) → ff-merge to `main` → `git push origin main`.
- Commit footer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **In-world verify (user, test pilot):** buttons readable/spaced on the real monitors (confirm any
  glyph renders — flip named glyph constants only after confirming); run the FCS dump tool → configs
  appear on the shared disk → UI DTC `IMPORT ALL` pulls all 3; put a junk file on a disk → DTC `SCAN`
  flags it → `CLEAN` (confirm) removes only the junk, keeps valid EH2 configs.

## Out of scope / YAGNI
- No network push/pull for the config import (shared-disk chosen). No per-file "confirm each" clean.
- No rewrite of `configkit.actionRow`'s internals (reuse it per-row).
- No changes to the config schema, the fused-file boot assembly, or the FCS flight app.
