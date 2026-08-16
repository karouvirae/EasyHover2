# EH2 Config UX Tweaks — Spec (2026-08-16)

**Formalized from the APPROVED, LOCKED design** (`2026-08-16-eh2-config-ux-tweaks-design.md`).
Every locked decision is carried through unchanged; this spec adds the concrete file/line/seam/test
detail confirmed by reading the current code, so the plan and implementers work from ground truth.

Repo: `C:\Users\m-kri\Claude Code\EasyHover2`. Base branch `main`, HEAD `ba08050` (design-doc commit).
Three independent UI/tool features in the EH2 config area. **No frozen flight-code changes**
(`fcs/**` flight/kernel untouched); the one FCS-side piece is a STANDALONE console tool.

Reference style for all UI work: `ui/basalt/bitconfig/senscal.lua` / `senssource.lua` (region
drilldowns + `configkit.actionRow`) and `ui/basalt/instruments/horizon.lua` (named-glyph pattern).

---

## Global constraints (apply to every feature)

- **Reuse, don't reinvent.** `configkit.actionRow` is called per-row, never rewritten. DTC reuses
  `M._scanKind/_importKind/validateKind/KINDS/FILE/resolveDeps`. The FCS tool copies the
  `tools/splitconfig.lua` shape (pure `M.plan`/`M.run` + injected `deps`). SuiteX install reuses
  `toolsToInstall`/`checkboxLabels`/`installToolIfRequested`/`installOneTool`.
- **Glyph caveat (LOCKED).** CC:Tweaked's font does NOT reliably render `⟳`/`✓`/`✕`. Use CC-native
  chars where they exist (`"\27"`=←, `"\26"`=→, `"\24"`/`"\25"`=↑/↓). For rescan/refresh/confirm/
  cancel (no safe native glyph), put the glyph in a **NAMED CONSTANT** the user confirms in-game
  (same pattern as `horizon.lua` `M.STYLE.subpixel.pair = "\140 "`), with a short-word fallback
  (`OK`, `RE-SCAN`, `CANCEL`). Prefer a short full word over an unrenderable glyph when in doubt.
- **TDD every task.** Pure seams first; RED before editing a manifested impl file (tests aren't
  manifested, so the sync-guard stays green while only tests change). Commit SOURCE + tests per
  task; leave `manifest*.lua`/`dist` dirty until the final build task.
- **Filenames never hardcoded.** FCS kinds resolve via `cfgspec.FILES[kind]`; DTC via `M.FILE`.
- **Gates (all three must stay green):** `bash tests/run_headless.sh`, `bash tests/run_headless_dist.sh`,
  `bash tests/run_suite_e2e.sh`. New `tests/test_*` register in BOTH `run_headless.sh` and
  `run_headless_dist.sh`.
- **Commit footer EXACTLY:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## Feature 1 — Readable multi-row / glyph buttons (MDB-Conf + DTC)

### Problem (confirmed)
`ui/basalt/configkit.lua` `M.actionRow(frame,pos,specs)` (line 203) computes
`M.splitWidths(pos.w, #specs)` — an EVEN division of one row's width across every button — then
`fitLabel`-truncates each label to its cell. 3+ buttons on a ~0.5-scale monitor each get a tiny cell
→ truncation like `SAVE ^CAN^ACK`. Both MDB (`mdb.lua:267` footer `SAVE/RESCAN/< BACK`) and DTC
(`dtc.lua:500` topRow `EXPORT/IMPORT/REFRESH`) over-pack a single row.

### Approach (LOCKED)
Stop cramming — lay buttons across MULTIPLE `actionRow` calls (1–2 buttons per row). Primary actions
keep full words with adequate width; compact nav/repeat actions become single-glyph buttons.
**Do NOT rewrite `actionRow`.** An optional small `configkit` convenience for stacked rows is
permitted but not required; if added it must be pure-ish chrome (Basalt objects only via params,
nothing at module load) and its own labels/glyphs pinned to named constants.

### Named glyph/label constants (new, in `configkit.lua` or a small shared table)
All button glyphs/labels used below live as **named constants** so a test can pin them and the user
can flip an unrenderable glyph after in-game confirmation. Initial values:
- `BACK = "\27"` (← — CC-native, safe).
- `RESCAN`/`REFRESH` glyph = a named constant, initial placeholder (e.g. `"\138"` or the short word
  `"RE-SCAN"`/`"REFR"`); **confirm in-game before trusting the glyph** — ship the short-word fallback
  if unsure.
- `CONFIRM_OK` / `CONFIRM_CANCEL` = named constants, initial `"OK"` / `BACK`. (No safe native ✓/✕.)

### Changes
- **MDB-Conf overview footer** (`mdb.lua`, `buildOverview`, ~line 267): replace the single
  `actionRow{ SAVE, RESCAN, < BACK }` with a `SAVE` full-width row, then a row of
  `RESCAN`(glyph/word) + `BACK`(`"\27"`) buttons. The 5 group buttons above stay as-is. `doRescan`
  stays a named local (tests invoke it directly).
- **DTC top screen** (`dtc.lua`, `buildTop`, ~line 500): `EXPORT` / `IMPORT` (2-up, full words) →
  `REFRESH`(glyph) + `SCAN`(Feature 3) row → `IMPORT ALL`(Feature 2) row → `BACK`(`"\27"`) row.
  Lay across rows so nothing truncates; mind small-monitor height (header + summary + ~4–6 rows).
- **DTC confirm screens** (`buildConfirm`, and Feature 2/3's new confirms): CONFIRM/`<` become the
  named `CONFIRM_OK` / `CONFIRM_CANCEL` constants (word fallbacks by default).
- Inner drilldown/group screens already use a single `<` — leave them.

### Testing
- `tests/test_bitconfig_mdb.lua` + `tests/test_bitconfig_dtc.lua` must stay green; UPDATE the cases
  that assert the old flat footer/topRow element shape to assert the new per-row structure via
  `region.built.<id>.handle.elements` (the shape the DTC Task-12 tests already use).
- Add `tests/test_configkit.lua` (or extend it) assertions pinning the new named glyph/label
  constants — so a value change is a deliberate, test-visible edit.
- No change to `splitWidths`/`fitLabel` behaviour or their existing tests.

---

## Feature 2 — Import all 3 FCS configs to the UI (via shared networked disk)

Goal: get the FCS's 3 correct configs (`eh2_devbind`, `eh2_senscal`, `eh2_tuning`) onto the UI PC in
~one action, via the shared networked disk. Two pieces.

### Piece 2a — New FCS-side console tool (STANDALONE, SuiteX-installed like `splitconfig`)
- **New file `tools/fcs2disk.lua`** (name locked to `fcs2disk`; launcher `fcs2disk`). Shape mirrors
  `tools/splitconfig.lua` EXACTLY:
  - **PURE core** `M.plan(existing)` → `{ action, kinds={…}, missing={…}, err? }`, where
    `existing = { present = {kind=bool}, mount }`. `action ∈ "write"|"abort"|"no-mount"`. Plans to
    write every FCS kind (`cfgspec.FILES` keys: devbind/senscal/tuning) whose local file is present;
    lists absent kinds in `missing`. `abort` only on no readable local configs at all.
  - **In-game** `M.run(deps)` → human summary string. `deps` (injected, defaults to real fs +
    `peripheral.find`): `read`, `write`(atomic), `exists`, `find`(→drive), optional `backup`.
    Resolve the disk via `deps.find("drive")` → `getMountPath()` (nil → `"no-mount"` summary,
    write nothing). For each present kind, read `/<cfgspec.FILES[kind]>` locally and write it to
    `<mount>/<cfgspec.FILES[kind]>` atomically. Never touch the FCS flight app; never hardcode
    filenames. Reports which kinds were dumped + which were missing.
- **New launcher `launchers/fcs2disk.lua`** (mirrors `launchers/splitconfig.lua`).
- **Manifest `tools` entry** in `tools/gen_manifest.lua` `TOOLS` table (mirror the `splitconfig`
  entry at line 105: `title`, `entry = "fcs2disk"`, `root = "launchers/fcs2disk.lua"`). It IS in the
  dist closure via `buildTool`.
- **SuiteX Advanced-tab wiring** (`easyhover2_suitex.lua`), mirroring `splitconfig` everywhere:
  - `SuiteX.toolsToInstall(flags)` (line 50): `if flags.installFcs2Disk then out[#out+1]="fcs2disk" end`.
  - New Advanced-tab checkbox via `SuiteX.checkboxLabels("FCS config dump (dump FCS configs to disk)")`
    (near line 712), wired to `flags.installFcs2Disk` like `splitOff/splitOn`.
  - `installToolIfRequested` (line 572): add `fcs2disk` to the `doneMsg` + `displayName` maps and to
    the `SuiteX.toolsToInstall{…}` flags table it passes.

### Piece 2b — UI DTC `IMPORT ALL`
- **New pure helper `M._importAll(mount, deps)`** in `ui/basalt/bitconfig/dtc.lua`:
  loops `M.KINDS`, importing each kind where `M._scanKind(mount,kind,deps).diskHas and .diskValid`
  (reuse `M._importKind`, which backs up the local file first). Returns
  `{ imported = {kinds…}, skipped = {kinds…} }` in `M.KINDS` order. `mount == nil` → both empty.
- **UI wiring** in `buildTop`: an `IMPORT ALL` button (Feature 1 row) that pushes a single confirm
  screen (`"confirm_importall"`) summarizing which valid kinds are present; CONFIRM runs
  `M._importAll`, records a one-line status (`"IMPORT ALL: N imported, M skipped"`), re-detects/
  re-scans, pops. `<`/CANCEL pops without acting. Reuse the existing per-row confirm-screen pattern
  (`buildConfirm`). Enabled only when the drive is present and ≥1 valid importable kind exists.

### Flow
Run `fcs2disk` on the FCS console → 3 configs land on the shared disk → carry disk / it's shared →
UI DTC → `IMPORT ALL` (one confirm) pulls all valid kinds. `uicfg` is UI-only (not on the FCS), so
`IMPORT ALL` simply imports whatever valid kinds are on the disk.

### Testing
- **New `tests/test_fcs2disk.lua`**: pure `M.plan` cases (all present / some missing / none / no
  mount) + `M.run` with an in-memory `deps` store (dumps present kinds to the mock mount, skips
  missing, no-mount path writes nothing). Register in both runners.
- **`tests/test_bitconfig_dtc.lua`**: `M._importAll` cases with the in-memory `deps` store the DTC
  tests already use (all valid → all imported; a corrupt/`BAD` disk kind → skipped; a `diskHas` but
  missing local → still imported with backup; `mount=nil` → empty). Plus a construction-probe test
  that the `IMPORT ALL` button + `confirm_importall` screen exist and gate on presence/validity.
- **`tests/test_suitex.lua`**: `toolsToInstall` returns `"fcs2disk"` when the flag is set; the
  checkbox labels exist.
- **`tests/test_manifest_tools.lua`**: `fcs2disk` appears in the built manifest `tools` with its
  closure.

---

## Feature 3 — DTC disk SCAN + CLEAN

Goal: detect a disk carrying foreign/other data but no clean EH2 config, and let the user wipe the
junk (keeping any valid EH2 config) before using the disk.

### Pure seams (new, in `dtc.lua`, TDD'd with injected deps)
- **`resolveDeps` extension** (line 259): add a `list` default (`deps.list or realList`, where
  `realList(path)` wraps `fs.list`), mirroring how `attributes`/`backup` were added in the
  config-overhaul batch. `realList` must be nil/absence-safe (missing/невalid path → `{}`).
- **`M._scanDisk(mount, deps)` → `{ valid = {kinds…}, foreign = {paths…}, invalid = {paths…} }`**:
  `deps.list(mount)` every filename; reverse-lookup filename against `M.FILE` (`filename → kind`):
  - **valid** — filename ∈ `M.FILE` AND `M.validateKind(kind, textutils.unserialise(read body))`;
    collect the kind.
  - **invalid** — an `eh2_*.tbl` (EH2-named, `M.FILE` value) that is missing-bodied / unparseable /
    fails `validateKind`; collect the path.
  - **foreign** — any other filename; collect the path.
  `mount == nil` → all three empty. Paths returned as full disk paths (`M.diskPath`-style or the
  `<mount>/<name>` join used for delete).
- **`M._cleanDisk(mount, deps)` → `{ deleted = {paths…} }`**: deletes ONLY the `foreign ∪ invalid`
  set (never a valid EH2 config) via `deps.delete`. `mount == nil` → empty. (Compute the set via
  `M._scanDisk` so scan and clean can never disagree.)
- **`M._scanSummary(scan)` → string** (PURE, display): e.g. `"valid N · foreign M · invalid K"`;
  flags "clean advised" when `#valid == 0` and `(#foreign + #invalid) > 0`.

### UI wiring (`buildTop` + new screens)
- **`SCAN` button** (Feature 1 row) → pushes a `"scan"` screen showing `M._scanSummary` + counts,
  and (if clean advised or any foreign/invalid present) a `CLEAN` button.
- **`CLEAN`** → pushes `"confirm_clean"` listing the exact paths to delete (foreign + invalid, keep
  valid), CONFIRM runs `M._cleanDisk`, records status, re-detects/re-scans, pops; `<`/CANCEL pops
  without acting. Reuse the per-row confirm-screen pattern.

### Testing
- **`tests/test_bitconfig_dtc.lua`**: `M._scanDisk` classification (valid EH2 config; a corrupt
  `eh2_*.tbl` → invalid; a `foo.txt` → foreign; empty disk; `mount=nil`) and `M._cleanDisk` (deletes
  only foreign+invalid, keeps valid; `mount=nil` no-op) with the in-memory `deps` store (now needs a
  `list` entry). `resolveDeps` supplies a `list` default. Construction-probe: `SCAN`/`CLEAN` buttons
  + `scan`/`confirm_clean` screens exist; CLEAN confirm lists only foreign+invalid.

---

## Architecture / data flow summary

```
FCS console:  fcs2disk  --(reads /eh2_*.tbl, writes <mount>/eh2_*.tbl)-->  SHARED DISK
                                                                              |
UI PC (DTC):  IMPORT ALL --(M._importAll: per-kind backup + import valid)----+
              SCAN       --(M._scanDisk: classify each file)-----------------+
              CLEAN      --(M._cleanDisk: delete foreign+invalid only)-------+
```
All disk IO flows through deps-injected seams (`read/write/exists/delete/move/attributes/backup/
find/list`) → every core function is headless-testable with an in-memory store; no real peripheral
or fs is touched in tests.

## Error handling
- No mount / no drive: every disk op is a no-op returning empty/`"no-mount"`; buttons disabled or the
  summary reads `"no disk"`.
- Unparseable/corrupt disk file: never imported (`diskValid` false → skipped by IMPORT ALL; classified
  `invalid` by SCAN, eligible for CLEAN). A local file is always backed up before an import overwrites it.
- CLEAN never deletes a valid EH2 config; the confirm screen lists the exact deletion set first.
- The FCS tool never writes/deletes the flight app or the fused file; missing local kinds are reported,
  not fabricated.

## Ship mechanics
Per-task: TDD (RED first), commit SOURCE + tests only, leave manifest/dist dirty. Final build task:
register new `tests/test_*` in `run_headless.sh` + `run_headless_dist.sh`, run
`node tools/build.mjs && bash tools/run_gen.sh`, run all three gates green, commit `dist`/`manifest*.lua`.
Whole-branch opus review (source-only) → ff-merge to `main` → `git push origin main`. Then update the
`eh2-config-overhaul-checkpoint` sibling memory and delete the handoff file.

## Out of scope / YAGNI (LOCKED)
No network push/pull (shared-disk chosen). No per-file "confirm each" clean. No rewrite of
`configkit.actionRow` internals. No config-schema / fused-boot-assembly / FCS-flight-app changes.
`easyhover2_suitex.lua` itself is NOT in the dist closure (standalone `wget run`) — but the tool's
manifest entry + dist files ARE.
