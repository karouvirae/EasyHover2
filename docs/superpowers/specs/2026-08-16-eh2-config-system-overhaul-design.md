# EH2 Config System Overhaul — Design Spec

**Date:** 2026-08-16
**Status:** Approved (brainstormed 2026-08-16)
**Related:** builds on the shipped DTC (`ui/basalt/bitconfig/dtc.lua`), FCS boot loader
(`fcs/boot/loaderui.lua` + `loader.lua`), config schema (`fcs/io/cfgspec.lua`), and the
Suite/SuiteX installer (`easyhover2_suite.lua` / `easyhover2_suitex.lua`).

## Goal

Improve the **accuracy and transparency** of the EasyHover2 config / DTC / disk system. Today the
config lives partly as a single legacy **fused** file (`eh2_hw_config.tbl`) that combines device
bindings and sensor calibration; some tools still write it directly; the DTC menu copies whole
file-sets with a fused/opaque model and no per-file visibility. This overhaul makes every *actual*
config a clean, separate, individually timestamped and individually replaceable file everywhere it is
authored, carried, or backed up — while leaving the FCS's internal fused runtime file (assembled at
boot for the flight app) exactly as it is.

## Non-negotiable constraints

- **The FCS flight/kernel code is FROZEN.** No edits to the flight controller, kernel, backend, or
  control loops. The boot loader (`fcs/boot/**`) and config tooling MAY change (this batch's remit).
- **The fused runtime file stays.** `eh2_hw_config.tbl` remains the file the frozen flight app
  (`tools/flight.lua`) reads. It is written **only** by the boot loader, which assembles it from the
  split files each boot. No authoring tool writes it anymore.
- **Non-destructive migrations.** The split migration never modifies or deletes the fused file; it
  only *adds* the split files, validated, so the original is always the fallback.
- **Commit footer** on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

## The four canonical config files

| Key | File | Contents | On FCS? | On UI PC? | FCS reads? |
|-----|------|----------|:-------:|:---------:|:----------:|
| `devbind` | `eh2_devbind.tbl` | Craft device bindings (thrusters/sensors/fuelRelay) | yes | yes | yes (boot) |
| `senscal` | `eh2_senscal.tbl` | Sensor calibration (signs/scales/idx, incl. signHeading/signYawRate) | yes | yes | yes (boot) |
| `tuning` | `eh2_tuning.tbl` | FCS tuning (gains/caps/feel) | yes | yes | yes (flight+boot) |
| `uicfg` | `eh2_ui_config.tbl` | UI PC config (monitors/fuel/relay/sens) | no | yes | **no** |

Plus the **fused runtime artifact** `eh2_hw_config.tbl` — FCS-only, boot-assembled from
`devbind`+`senscal`, read by the flight app. Not an authoring file, not a DTC transport file.

Filenames for the three FCS kinds come from `cfgspec.FILES` so they can never drift from the schema
or from the boot loader's `diskSource` path.

## Architecture: three phases in one plan

Ordered so the file separation is a solid, tested base before the DTC UI manipulates the files
per-file. Confirmations (Phase 3) fold into Phases 1–2 where efficient.

---

### Phase 1 — Clean config-file separation (foundation)

**1a. Write-source fixes (the separation invariant).** Every authoring path writes exactly one
canonical split file; only the boot loader writes the fused file.

- `tools/probe.lua` — its *bind* action currently writes the fused `eh2_hw_config.tbl` via a local
  `saveConfig`. Change it to load/save **`eh2_devbind.tbl`** via `cfgspec` (`cfgspec.load("devbind", …)`
  / `cfgspec.save("devbind", …)`), with legacy read-through (seed from the fused file if the split
  file is absent, mirroring `binddevices.lua`). Device bindings ARE `devbind`.
- `tools/fix_yaw_sign.lua` — currently reads/writes the fused file to set `bindings.signHeading` /
  `bindings.signYawRate`. Change it to load/patch/save **`eh2_senscal.tbl`** via `cfgspec`
  (`senscal` is the `bindings` sub-table), with legacy read-through if only the fused file exists.
- No change needed (already split): `tools/calibrate.lua`→`senscal`, `tools/binddevices.lua`→
  `devbind`, UI `bitconfig/mdb`→`devbind`, `bitconfig/senscal`→`senscal`, `bitconfig/tuning`→`tuning`.
- `fcs/boot/loaderui.lua` — unchanged as the sole writer of the fused runtime file.

**1b. Suite(X) split-migration tool.** A new standalone tool run on the FCS console, installed via the
SuiteX Advanced tab, following the established beacon-updater pattern
(`tools/<name>.lua` + `launchers/<name>.lua` + manifest `tools` entry + SuiteX Advanced-tab checkbox).

- Name: `tools/splitconfig.lua`, launcher `splitconfig`.
- **Pure core** (headless-tested): `derive(fusedTable) -> devbind, senscal` (via `cfgspec.splitLegacy`
  + defaults-merge) and validation via `cfgspec.validate`.
- **In-game run** (safe + idempotent):
  1. If both `eh2_devbind.tbl` and `eh2_senscal.tbl` already exist → report "already split", no-op.
  2. Read `eh2_hw_config.tbl`; if absent or unparseable → abort, nothing written.
  3. Derive `devbind`+`senscal`; **validate both** (`cfgspec.validate`). Any failure → abort, nothing
     written.
  4. Atomically write the missing split file(s). Never clobber an existing split file without an
     explicit confirmation.
  5. **Never touch `eh2_hw_config.tbl`.** It stays as the fallback; `splitLegacy` is exact, so the
     next boot's reassembly is byte-equivalent. Deleting the two new files restores the legacy state.
  6. Refresh the FCS backup of the newly written split files (cheap immediate safety).
  7. Report exactly what it wrote (files + validation result).

**1c. Backups (single-latest, all files).**
- Fix `Suite.backupConfig` (`easyhover2_suite.lua:340`): today it deletes the *entire* backup folder
  on every call, so it can only ever hold one file. Change to single-latest **per file** (clear only
  that file's prior copy in `/easyhover2_backup`, then write it) so multiple configs coexist.
- Expand each role's `configs` list in `tools/gen_manifest.lua`:
  - `fcs` → `{ eh2_devbind, eh2_senscal, eh2_tuning, eh2_hw_config }`
  - `ui`  → `{ eh2_devbind, eh2_senscal, eh2_tuning, eh2_ui_config }` (no fused file on the UI PC)
- Backups refresh on **Suite install/update runs** (existing mechanism, now covering all files) and
  **before a DTC IMPORT overwrites a local file** (Phase 2). `splitconfig` also backs up what it writes.

---

### Phase 2 — Improved DTC / disk system (UI PC)

**2a. 4-kind registry.** Decouple DTC from `cfgspec.FILES` with an ordered registry of the four kinds.
Each entry: `{ key, file, label, validate }`. The three FCS kinds source their `file` from
`cfgspec.FILES` (so `diskPath` still matches the boot loader's `diskSource`; the existing path-layout
test in `tests/test_bitconfig_dtc.lua` stays satisfied). `uicfg.file = "eh2_ui_config.tbl"`.
Per-kind `validate(table) -> bool`: `cfgspec.validate(kind, …)` for the FCS kinds; a `ui.config`
shape-check for `uicfg`.

**2b. Top DTC screen.** Buttons `EXPORT (UI PC → disk)`, `IMPORT (disk → UI PC)`, `REFRESH`, plus a
disk summary line (drive present? disk label? "valid config: N/4"). Directional labels remove the
export/import ambiguity. EXPORT/IMPORT are drilldowns (Region), REFRESH re-detects the drive + rescans.

**2c. Export & Import drilldowns.** Each is a 4-row overview (one row per kind). Each row shows:
- kind label,
- **local**: present? + timestamp,
- **disk**: present? + timestamp + validity,
- a newer / older / missing indicator.

Timestamps come from `fs.attributes(path).modified` (ms epoch) formatted with `os.date`.
Selecting a row triggers the directional action for that one kind:
- **Export row**: confirm ("Overwrite `<file>` on the disk?") → atomic local→disk copy → refresh + result.
- **Import row**: allowed only if the disk file is present + valid → confirm ("Overwrite `<file>` on the
  UI PC?") → back up the local file → atomic disk→local copy → refresh + result.

All disk-IO stays behind the existing injected `deps` seam (`_detect`/`_scan`/`_export`/`_import` +
new per-kind variants) so the module is headless-testable and loads clean (no peripheral/fs at load).

---

### Phase 3 — Confirmations (folded in)

- **FCS boot loader** (`fcs/boot/loaderui.lua`): after a concern's source is picked, if it is `disk`
  or `ui` (not `own`/`defaults`), prompt a Y/N confirm before committing — that source changes what
  the FCS flies. `own`/`defaults` need no confirm.
- **DTC**: the per-file confirm on every export/import action (Phase 2).

---

## Data flow (unchanged where frozen)

- **FCS boot** still sources each concern independently (`binding`/`sensor`/`tuning` → `own`/`ui`/
  `disk`/`defaults`), assembles `hw = assembleHw(binding, sensor)` + `tuning`, and writes
  `eh2_hw_config.tbl` + `eh2_tuning.tbl`. After migration the `own` source reads the split files
  directly instead of the legacy read-through.
- **Disk** carries the split files only; the fused file is never transported.
- **UI PC** authors the four files; the FCS never reads `eh2_ui_config.tbl`.

## File structure

**Create:** `tools/splitconfig.lua`, `launchers/splitconfig.lua`,
`tests/test_splitconfig.lua`, `tests/test_dtc_*` additions as needed.
**Modify:** `tools/probe.lua`, `tools/fix_yaw_sign.lua`, `easyhover2_suite.lua` (backupConfig),
`tools/gen_manifest.lua` (role configs), `easyhover2_suitex.lua` (Advanced-tab checkbox + tool
install), `ui/basalt/bitconfig/dtc.lua` (registry + drilldowns + confirms + timestamps + validity),
`fcs/boot/loaderui.lua` (source confirm), the manifest `tools` section, and the relevant tests
(`tests/test_bitconfig_dtc.lua`, `tests/test_suite*.lua`, `tests/test_manifest_tools.lua`).

## Testing & ship

- Headless-tested pure cores: `splitconfig.derive`/validate, DTC kind-registry / `plan` / path /
  timestamp-format / per-kind validators, `Suite.backupConfig` per-file behavior.
- Gates: `tests/run_headless.sh` + `tests/run_headless_dist.sh` + `tests/run_suite_e2e.sh`; manifests
  IN SYNC via `node tools/build.mjs && bash tools/run_gen.sh`. New `tests.test_*` modules register in
  BOTH headless harnesses.
- Whole-branch review → ff-merge to `main` → `git push origin main`.

## Out of scope

- Any change to the frozen flight/FCS-kernel code, or to what the flight app reads (`eh2_hw_config.tbl`).
- Versioned backup history (single-latest only, by decision).
- Eliminating the fused runtime file.
- Transporting the fused file via DTC/disk.

## Open risks for the implementer

- `probe.lua`'s config object is the full `hwconfig` shape; when writing `devbind`, persist only the
  `devbind` subset (thrusters/sensors/fuelRelay) via `cfgspec.save("devbind", …)`.
- Adding the `uicfg` kind to DTC requires a validator that doesn't go through `cfgspec` (use
  `ui.config`); keep the three FCS kinds' disk paths sourced from `cfgspec.FILES` so
  `tests/test_bitconfig_dtc.lua`'s path-layout match with `loaderui.diskSource` still holds.
- `fs.attributes` returns `modified` in ms since epoch (field renamed from `modification` in CC
  1.91.0); MC 1.21.1 CC:Tweaked uses `modified`. Divide by 1000 for `os.date`.
- The SuiteX Advanced-tab tool-install path reuses `Suite.writeRelease`; mirror the beacon-updater
  wiring exactly (manifest `tools` section via `buildTool`).
