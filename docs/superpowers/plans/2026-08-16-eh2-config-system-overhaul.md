# EH2 Config System Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every actual EH2 config a clean, separate, individually timestamped and replaceable file everywhere it is authored, carried, or backed up — while leaving the FCS's internal fused runtime file (`eh2_hw_config.tbl`, assembled at boot) untouched — and overhaul the DTC/disk menu for per-file, transparent, confirmed export/import.

**Architecture:** Three ordered phases in one plan. **Phase 1** makes separation a tested base: convert the two remaining fused-writers (`probe`, `fix_yaw_sign`) to write split files via `cfgspec`, add a safe idempotent SuiteX-installed `splitconfig` migration for legacy FCS PCs, fix `Suite.backupConfig` to single-latest-per-file, and expand the role backup sets. **Phase 2** rebuilds the DTC menu around a 4-kind registry (adds UI config), with disk+local timestamps, validity, per-file selective export/import drilldowns, and confirmations. **Phase 3** folds in the FCS-boot source confirmation. The frozen flight/FCS-kernel code is never touched.

**Tech Stack:** Lua 5.1 (CC:Tweaked), Basalt 2.0 full build, CraftOS-PC headless harness, `tests/framework.lua`, `node tools/build.mjs` + `tools/run_gen.sh`.

## Global Constraints

- **Spec (implicit requirements for every task):** `docs/superpowers/specs/2026-08-16-eh2-config-system-overhaul-design.md`.
- **FCS flight/kernel code is FROZEN.** No edits under `fcs/**` EXCEPT the boot loader `fcs/boot/loaderui.lua` (Phase 3 confirm) which this batch explicitly owns. Never touch `fcs/io/backend.lua`, control loops, kernel, or `tools/flight.lua`'s read target.
- **The fused runtime file stays.** `eh2_hw_config.tbl` is written ONLY by the boot loader (`fcs/boot/loaderui.lua`), read by the frozen flight app. No authoring tool writes it after this batch.
- **Canonical files:** `eh2_devbind.tbl` (bindings), `eh2_senscal.tbl` (sensor cal), `eh2_tuning.tbl` (tuning), `eh2_ui_config.tbl` (UI-only). Filenames for the 3 FCS kinds come from `cfgspec.FILES`.
- **Non-destructive migration:** `splitconfig` never modifies/deletes the fused file; only adds validated split files; aborts on any validation failure.
- **No peripheral/Basalt/fs/os access at module LOAD** — every module `require()`s clean headless; peripheral/fs work lives in functions/closures. Pure helpers take plain tables in, values out.
- **Manifests regen is deferred to the final gates task.** During each task the headless harness sync-guard regenerates `manifest*.lua`/`dist/**`; do NOT commit generated artifacts until Task 14. Commit only source + tests per task.
- **Commit footer** on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```

## Reference: exact APIs to build on (verified in source)

- `fcs/io/cfgspec.lua`:
  - `M.FILES = { devbind="eh2_devbind.tbl", senscal="eh2_senscal.tbl", tuning="eh2_tuning.tbl" }`
  - `M.load(kind, read) -> merged, existed, err` (`read(path)->body|nil`; defaults-merged even when absent)
  - `M.save(kind, cfg, write) -> ...` (`write(filename_without_leading_slash, body)`)
  - `M.merge(kind, saved)`; `M.validate(kind, cfg) -> ok, err` (req: devbind={"thrusters","sensors"}, senscal={"signPitch","signHeading"}, tuning={"gains","caps","feel"})
  - `M.splitLegacy(hw) -> { devbind={thrusters,sensors,fuelRelay}, senscal=hw.bindings }`
- `fcs/io/fsx.lua`: `fsx.read` (path->body|nil), `fsx.writeAtomic` (path, body).
- `ui/config.lua`: `M.withDefaults(cfg)`, `M.load(path)->cfg,existed,err`, `M.save(path,cfg)`; UI file path `/eh2_ui_config.tbl`.
- `easyhover2_suite.lua`: `Suite.backupConfig(path, version)`; `BACKUP_ROOT="/easyhover2_backup"`; backup filename = `path:gsub("^/",""):gsub("/","_")`.
- `fs.attributes(path) -> { size, isDir, isReadOnly, created, modified }` (`modified` = ms since epoch).
- `ui/basalt/bitconfig/dtc.lua`: `M.KINDS`, `M.plan`, `M.localPath(kind)`, `M.diskPath(mount,kind)`, `M._detect/_scan/_export/_import`, `M.build`. `diskPath` MUST equal `fcs/boot/loaderui.lua`'s `diskSource` path for the 3 FCS kinds (enforced by `tests/test_bitconfig_dtc.lua`).
- Split-write template: `tools/binddevices.lua` `loadBinding` (cfgspec.load → splitLegacy read-through → cfgspec.save). Tool-wiring template: `tools/beaconupdate.lua` + `launchers/beaconupdate.lua` + `gen_manifest.lua` `TOOLS.beaconupdate`/`buildTool` + `easyhover2_suitex.lua` `installToolIfRequested`.

---

## Phase 1 — Clean config-file separation (foundation)

### Task 1: `splitconfig` pure core

**Files:** Create `tools/splitconfig.lua`; Create `tests/test_splitconfig.lua`; Modify `tests/run_headless.sh` (add `"tests.test_splitconfig"`).

**Interfaces:**
- Produces: `M.plan(existing) -> { action, devbind?, senscal?, err? }` where `existing = { fused=<table|nil>, hasDevbind=bool, hasSenscal=bool }`. Pure, no IO.
  - `action="already-split"` when `hasDevbind and hasSenscal` (no writes needed).
  - `action="abort"`, `err=...` when the fused table is nil/not-a-table, or when a derived split fails `cfgspec.validate`.
  - `action="write"`, `devbind=<table>`, `senscal=<table>` (only the missing ones populated) when derivation + validation succeed.

- [ ] **Step 1: Register the suite** — append `"tests.test_splitconfig"` to `local suites = { ... }` in `tests/run_headless.sh`.

- [ ] **Step 2: Write the failing test** — create `tests/test_splitconfig.lua`:
```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local S = require("tools.splitconfig")
local cfgspec = require("fcs.io.cfgspec")

local function fused()
  return {
    thrusters = { FL = "thruster_1" }, sensors = { gimbal = "gimbal_1", velMedial = "vel_1" },
    fuelRelay = "redstone_relay_0",
    bindings = { signPitch = 1, signHeading = -1, gimbalScale = 1 },
  }
end

t.test("plan derives + validates devbind and senscal from a fused table", function()
  local r = S.plan({ fused = fused(), hasDevbind = false, hasSenscal = false })
  t.eq(r.action, "write")
  t.eq(r.devbind.thrusters.FL, "thruster_1")
  t.eq(r.devbind.sensors.gimbal, "gimbal_1")
  t.eq(r.senscal.signPitch, 1)
  t.truthy(cfgspec.validate("devbind", r.devbind), "devbind valid")
  t.truthy(cfgspec.validate("senscal", r.senscal), "senscal valid")
end)

t.test("plan is a no-op when both split files already exist", function()
  local r = S.plan({ fused = fused(), hasDevbind = true, hasSenscal = true })
  t.eq(r.action, "already-split")
end)

t.test("plan only fills the missing split when one already exists", function()
  local r = S.plan({ fused = fused(), hasDevbind = true, hasSenscal = false })
  t.eq(r.action, "write"); t.eq(r.devbind, nil); t.truthy(r.senscal, "senscal derived")
end)

t.test("plan aborts on a nil/invalid fused table", function()
  t.eq(S.plan({ fused = nil, hasDevbind = false, hasSenscal = false }).action, "abort")
  t.eq(S.plan({ fused = "x", hasDevbind = false, hasSenscal = false }).action, "abort")
end)
```

- [ ] **Step 3: Run — expect RED** (`bash tests/run_headless.sh`): SUITE LOAD FAILURE `tools.splitconfig` not found.

- [ ] **Step 4: Implement** — create `tools/splitconfig.lua`:
```lua
-- tools/splitconfig.lua
-- Migrates a legacy FUSED /eh2_hw_config.tbl into the separate eh2_devbind.tbl + eh2_senscal.tbl
-- files, non-destructively. PURE core here (plan()); the in-game run()/backup lives below and is not
-- headless-tested. Never touches the fused file -- it stays as the fallback (splitLegacy is exact).
local cfgspec = require("fcs.io.cfgspec")

local M = {}

-- plan(existing) -> { action, devbind?, senscal?, err? }. existing = { fused, hasDevbind, hasSenscal }.
function M.plan(existing)
  existing = existing or {}
  if existing.hasDevbind and existing.hasSenscal then return { action = "already-split" } end
  if type(existing.fused) ~= "table" then return { action = "abort", err = "no readable fused config" } end
  local split = cfgspec.splitLegacy(existing.fused)
  local out = { action = "write" }
  if not existing.hasDevbind then
    local db = cfgspec.merge("devbind", split.devbind)
    local ok, err = cfgspec.validate("devbind", db)
    if not ok then return { action = "abort", err = "devbind invalid: " .. tostring(err) } end
    out.devbind = db
  end
  if not existing.hasSenscal then
    local sc = cfgspec.merge("senscal", split.senscal)
    local ok, err = cfgspec.validate("senscal", sc)
    if not ok then return { action = "abort", err = "senscal invalid: " .. tostring(err) } end
    out.senscal = sc
  end
  return out
end

return M
```

- [ ] **Step 5: Run — expect GREEN** (`bash tests/run_headless.sh` → `OK`).

- [ ] **Step 6: Commit** — `git add tools/splitconfig.lua tests/test_splitconfig.lua tests/run_headless.sh && git commit`.

### Task 2: `splitconfig` in-game run + launcher

**Files:** Modify `tools/splitconfig.lua` (add `M.run`); Create `launchers/splitconfig.lua`. No new unit test (fs/backup glue; the decision logic is covered by Task 1). Verify `require("tools.splitconfig")` still loads clean headless.

**Interfaces:**
- Consumes: `M.plan` (Task 1), `fcs.io.cfgspec`, `fcs.io.fsx`.
- Produces: `M.run(deps?)` — reads `/eh2_hw_config.tbl`, checks which split files exist, calls `M.plan`, and on `action="write"` atomically writes the missing split file(s) via `cfgspec.save` and backs them up. `deps` (all defaulted to real fs) = `{ read, write, exists, backup }` so the path is injectable if a future test wants it.

- [ ] **Step 1: Add `M.run`** — append to `tools/splitconfig.lua` (above `return M`):
```lua
local fsx = require("fcs.io.fsx")
local FUSED = "/eh2_hw_config.tbl"

local function realExists(path) return fs.exists(path) and not fs.isDir(path) end

-- In-game only. Non-destructive: never writes/deletes the fused file. Returns a human summary string.
function M.run(deps)
  deps = deps or {}
  local read   = deps.read   or fsx.read
  local write  = deps.write  or fsx.writeAtomic
  local exists = deps.exists or realExists
  local hasDevbind = exists("/" .. cfgspec.FILES.devbind)
  local hasSenscal = exists("/" .. cfgspec.FILES.senscal)
  local fusedBody = read(FUSED)
  local fused = fusedBody and textutils.unserialise(fusedBody) or nil
  local r = M.plan({ fused = fused, hasDevbind = hasDevbind, hasSenscal = hasSenscal })
  if r.action == "already-split" then return "Already split -- eh2_devbind.tbl + eh2_senscal.tbl present. No change." end
  if r.action == "abort" then return "ABORT: " .. tostring(r.err) .. " (nothing written; fused file untouched)." end
  local wrote = {}
  if r.devbind then cfgspec.save("devbind", r.devbind, write); wrote[#wrote + 1] = cfgspec.FILES.devbind end
  if r.senscal then cfgspec.save("senscal", r.senscal, write); wrote[#wrote + 1] = cfgspec.FILES.senscal end
  if deps.backup then for _, fn in ipairs(wrote) do deps.backup("/" .. fn) end end
  return "Split OK -- wrote " .. table.concat(wrote, ", ") .. " (fused file left intact as fallback)."
end
```

- [ ] **Step 2: Create the launcher** — `launchers/splitconfig.lua` (mirror `launchers/beaconupdate.lua`'s shape; keep it minimal):
```lua
-- launchers/splitconfig.lua -- run the legacy-config split migration on the FCS.
package.path = "/?.lua;/?/init.lua;" .. package.path
local splitconfig = require("tools.splitconfig")
print("== EH2 SPLIT CONFIG ==")
print(splitconfig.run())
```
(If `launchers/beaconupdate.lua` uses a different bootstrap/`package.path` idiom, match it exactly.)

- [ ] **Step 3: Run — expect GREEN** (`bash tests/run_headless.sh`): existing tests still pass and `require("tools.splitconfig")` loads clean (Task 1's suite still green; `M.run` body touches fs only when called).

- [ ] **Step 4: Commit** — `git add tools/splitconfig.lua launchers/splitconfig.lua && git commit`.

### Task 3: Register `splitconfig` in the manifest TOOLS

**Files:** Modify `tools/gen_manifest.lua` (`TOOLS` table); Modify `tests/test_manifest_tools.lua` (extend to assert the new tool is present).

**Interfaces:** Produces: `manifest.tools.splitconfig = { title, entry="splitconfig", root="launchers/splitconfig.lua", files=... }` (built by `buildTool`).

- [ ] **Step 1: Write the failing test** — append to `tests/test_manifest_tools.lua` a case asserting the generated/among-declared tools includes `splitconfig` with `entry == "splitconfig"` (mirror the file's existing `beaconupdate` assertion — open it and copy that assertion's shape, swapping the name).

- [ ] **Step 2: Run — expect RED.**

- [ ] **Step 3: Implement** — in `tools/gen_manifest.lua` `TOOLS`, add alongside `beaconupdate`:
```lua
  splitconfig = {
    title = "Split legacy config",
    entry = "splitconfig",
    root  = "launchers/splitconfig.lua",
  },
```
(Match the exact field set `TOOLS.beaconupdate` uses; `buildTool` resolves the launcher's closure.)

- [ ] **Step 4: Run — expect GREEN.**

- [ ] **Step 5: Commit** — `git add tools/gen_manifest.lua tests/test_manifest_tools.lua && git commit`.

### Task 4: SuiteX Advanced-tab install for `splitconfig`

**Files:** Modify `easyhover2_suitex.lua` (Advanced-tab checkbox + `installToolIfRequested`). Test: extend an existing `tests/test_suitex.lua` case if it exercises `installToolIfRequested`/tool plan; otherwise a construction/no-crash assertion.

**Interfaces:** Produces: a second Advanced-tab "Optional tools" checkbox ("Split config") whose ticked state makes a successful install also lay down the `splitconfig` tool via `ctx.manifest.tools.splitconfig` + `Suite.writeRelease`.

- [ ] **Step 1: Study the template** — read `easyhover2_suitex.lua` `installToolIfRequested` (~line 520) and the Advanced-tab checkbox block (~line 660-679) for `beaconupdate`. Generalize `installToolIfRequested` to install EACH ticked optional tool (iterate a small `{ key=checkboxState }` list: `beaconupdate`, `splitconfig`), reading `ctx.manifest.tools[key]` and reusing the exact same verify→`Suite.writeRelease`→logLine flow.

- [ ] **Step 2: Add the checkbox** — mirror the beaconupdate checkbox exactly (label "Split config"; same widget/position idiom, one row below), storing its state on `ctx` the same way.

- [ ] **Step 3: Run — expect GREEN** (`bash tests/run_headless.sh` — SuiteX headless tests still pass; module loads clean). If `tests/test_suitex.lua` asserts the tool-install set, extend it to include `splitconfig` and confirm GREEN.

- [ ] **Step 4: Commit** — `git add easyhover2_suitex.lua tests/test_suitex.lua && git commit`.

### Task 5: `probe.lua` writes split `devbind` (not the fused file)

**Files:** Modify `tools/probe.lua`; Test: extend `tests/test_probe.lua` if it exists (assert the pure `M.bind` still maps roles correctly); the load/save conversion is verified by reading + the suite staying green.

**Interfaces:** Produces: `probe`'s bind action loads/saves `eh2_devbind.tbl` via `cfgspec` (legacy read-through), never writing `eh2_hw_config.tbl`.

- [ ] **Step 1: Study the template** — read `tools/binddevices.lua` `loadBinding` (cfgspec.load("devbind") → if not existed, `cfgspec.splitLegacy(legacy).devbind` read-through) and its `cfgspec.save("devbind", cfg, realWrite)`.

- [ ] **Step 2: If a probe test exists, add/keep a failing assertion** — in `tests/test_probe.lua` assert `M.bind({thrusters={FL=false},sensors={},fuelRelay=false}, "FL", "thruster_9").thrusters.FL == "thruster_9"` (pure, already true) AND — if the file can reach it — that the save path targets devbind. If no test file, skip to Step 3 (the change is a read/save-target swap verified by reading + green suite).

- [ ] **Step 3: Implement** — in `tools/probe.lua`:
  - Replace `local CONFIG_PATH = "/eh2_hw_config.tbl"` + `loadConfig`/`saveConfig` (the fused fs helpers) with a cfgspec-backed `loadBinding(read)` (copy `binddevices.lua`'s `loadBinding` verbatim) and `cfgspec.save("devbind", config, realWrite)` on bind.
  - Add `local cfgspec = require("fcs.io.cfgspec")` and `local fsx = require("fcs.io.fsx")`; `local realRead = fsx.read`, `local realWrite = fsx.writeAtomic`.
  - In `M.run`, `local config = loadBinding(realRead)`; on the bind branch: `config = M.bind(config, role, name); cfgspec.save("devbind", config, realWrite)`.
  - `M.bind` itself is unchanged (it already only edits thrusters/sensors/fuelRelay — the devbind subset). The Backend/sensors/timing branches that read `config` still work (devbind carries thrusters/sensors; those branches don't need the senscal `bindings`). Confirm no probe branch depends on `config.bindings`; if one does, note it and leave that branch reading the fused file read-only (do NOT write fused).

- [ ] **Step 4: Run — expect GREEN** (`bash tests/run_headless.sh`).

- [ ] **Step 5: Commit** — `git add tools/probe.lua tests/test_probe.lua && git commit` (omit the test path if none).

### Task 6: `fix_yaw_sign.lua` patches split `senscal` (not the fused file)

**Files:** Modify `tools/fix_yaw_sign.lua`. No unit test (it is a top-level in-game script, not a module); verify the suite stays green and the module/script parses.

**Interfaces:** Produces: `fix_yaw_sign` loads `eh2_senscal.tbl` via `cfgspec` (legacy read-through if only the fused file exists), sets `signHeading=-1`/`signYawRate=1`, saves `eh2_senscal.tbl`. Never writes the fused file.

- [ ] **Step 1: Implement** — rewrite `tools/fix_yaw_sign.lua`'s body:
```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local cfgspec = require("fcs.io.cfgspec")
local fsx = require("fcs.io.fsx")
local LEGACY = "/eh2_hw_config.tbl"

local cfg, existed = cfgspec.load("senscal", fsx.read)
if not existed then
  local body = fsx.read(LEGACY)
  local legacy = body and textutils.unserialise(body) or nil
  if type(legacy) == "table" then cfg = cfgspec.merge("senscal", cfgspec.splitLegacy(legacy).senscal)
  else print("No senscal or legacy config found -- run /calibrate first; nothing to patch."); return end
end
local oh, oy = cfg.signHeading, cfg.signYawRate
cfg.signHeading = -1
cfg.signYawRate = 1
cfgspec.save("senscal", cfg, fsx.writeAtomic)
print(("signHeading: %s -> -1"):format(tostring(oh)))
print(("signYawRate: %s -> 1  (reverting the earlier wrong flip)"):format(tostring(oy)))
print("Saved to " .. cfgspec.FILES.senscal .. ". Now launch:  hovertest")
```
(Keep the file's existing explanatory header comment block; only the executable body changes. `senscal` fields live at the top level of the senscal table, i.e. `cfg.signHeading`, matching `cfgspec.defaults("senscal") = hw.bindings`.)

- [ ] **Step 2: Run — expect GREEN** (`bash tests/run_headless.sh` — no new test; confirm nothing imports/breaks).

- [ ] **Step 3: Commit** — `git add tools/fix_yaw_sign.lua && git commit`.

### Task 7: `Suite.backupConfig` — single-latest PER FILE

**Files:** Modify `easyhover2_suite.lua` (`Suite.backupConfig`, ~line 340); Test: extend `tests/test_suite.lua` (backup behavior).

**Interfaces:** Produces: `Suite.backupConfig(path, version)` clears only THAT file's prior backup copy (not the whole folder), so multiple configs coexist in `/easyhover2_backup`.

- [ ] **Step 1: Write the failing test** — append to `tests/test_suite.lua` a case that backs up two distinct config paths and asserts BOTH copies exist afterward. Match the file's existing fs-mock/seam conventions (open it; mirror how other `Suite.*` tests stub `fs`). If `Suite.backupConfig` touches real `fs` directly with no seam, drive it against real CraftOS `fs` in the harness (create two temp files, back up each, assert both `/easyhover2_backup/<name>` exist):
```lua
t.test("backupConfig keeps one latest copy PER FILE (does not wipe siblings)", function()
  local a, b = "/eh2_devbind.tbl", "/eh2_senscal.tbl"
  local fa = fs.open(a, "w"); fa.write("A"); fa.close()
  local fb = fs.open(b, "w"); fb.write("B"); fb.close()
  Suite.backupConfig(a, "v"); Suite.backupConfig(b, "v")
  t.truthy(fs.exists("/easyhover2_backup/eh2_devbind.tbl"), "first survives")
  t.truthy(fs.exists("/easyhover2_backup/eh2_senscal.tbl"), "second present")
  fs.delete(a); fs.delete(b); fs.delete("/easyhover2_backup")
end)
```
(Adjust `Suite` require-local to the file's convention.)

- [ ] **Step 2: Run — expect RED** (the first backup is wiped by the second's folder-delete).

- [ ] **Step 3: Implement** — in `easyhover2_suite.lua` `Suite.backupConfig`, replace the whole-folder delete with a per-file clear:
```lua
function Suite.backupConfig(path, version)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  if not fs.exists(BACKUP_ROOT) then fs.makeDir(BACKUP_ROOT) end
  local name = path:gsub("^/", ""):gsub("/", "_")
  local target = ("%s/%s"):format(BACKUP_ROOT, name)
  if fs.exists(target) then fs.delete(target) end
  local f = fs.open(path, "r"); local body = f.readAll(); f.close()
  local w = fs.open(target, "w"); w.write(body or ""); w.close()
  backedUp[#backedUp + 1] = target
  return target
end
```
Update the function's header comment to say "single-latest PER FILE".

- [ ] **Step 4: Run — expect GREEN.**

- [ ] **Step 5: Commit** — `git add easyhover2_suite.lua tests/test_suite.lua && git commit`.

### Task 8: Expand role backup config sets

**Files:** Modify `tools/gen_manifest.lua` (`ROLES.fcs.configs`, `ROLES.ui.configs`); Test: extend `tests/test_manifest_channels.lua` or the manifest test that asserts role configs (or `tests/test_suite.lua`) to assert the new sets.

**Interfaces:** Produces: `fcs.configs = { "/eh2_devbind.tbl", "/eh2_senscal.tbl", "/eh2_tuning.tbl", "/eh2_hw_config.tbl" }`; `ui.configs = { "/eh2_devbind.tbl", "/eh2_senscal.tbl", "/eh2_tuning.tbl", "/eh2_ui_config.tbl" }`.

- [ ] **Step 1: Write the failing test** — add/extend a test asserting `ROLES.fcs.configs` and `ROLES.ui.configs` contain exactly the sets above (find the test that reads role specs; if none asserts `configs`, add a focused one requiring `tools.gen_manifest` and checking the tables).

- [ ] **Step 2: Run — expect RED.**

- [ ] **Step 3: Implement** — in `tools/gen_manifest.lua`:
  - `fcs`: `configs = { "/eh2_devbind.tbl", "/eh2_senscal.tbl", "/eh2_tuning.tbl", "/eh2_hw_config.tbl" }`
  - `ui`: `configs = { "/eh2_devbind.tbl", "/eh2_senscal.tbl", "/eh2_tuning.tbl", "/eh2_ui_config.tbl" }`
  (Leave `nav`/`beacon` configs unchanged. `configModule`/`luaPath` unchanged.)

- [ ] **Step 4: Run — expect GREEN.**

- [ ] **Step 5: Commit** — `git add tools/gen_manifest.lua tests/*.lua && git commit`.

---

## Phase 2 — Improved DTC / disk system (UI PC)

### Task 9: DTC 4-kind registry + per-kind validators

**Files:** Modify `ui/basalt/bitconfig/dtc.lua` (`M.KINDS` → registry, add validators, add `uicfg`); Modify `tests/test_bitconfig_dtc.lua` (extend); confirm the diskPath layout test still matches `loaderui.diskSource`.

**Interfaces:**
- Produces:
  - `M.KINDS = { "devbind", "senscal", "tuning", "uicfg" }` (ordered).
  - `M.FILE = { devbind=cfgspec.FILES.devbind, senscal=cfgspec.FILES.senscal, tuning=cfgspec.FILES.tuning, uicfg="eh2_ui_config.tbl" }` — `M.localPath`/`M.diskPath` resolve filenames from `M.FILE` (the 3 FCS kinds still equal `cfgspec.FILES`, so the boot-loader path match holds).
  - `M.LABEL = { devbind="Craft bindings", senscal="Sensor cal", tuning="FCS tuning", uicfg="UI config" }`.
  - `M.validateKind(kind, tableOrNil) -> bool` — `cfgspec.validate(kind, t)` for the 3 FCS kinds; for `uicfg`, `type(t)=="table"` (a UI config is any table `ui.config.withDefaults` can merge). Nil/non-table → false.

- [ ] **Step 1: Write the failing test** — append to `tests/test_bitconfig_dtc.lua`:
```lua
t.test("registry carries 4 kinds incl uicfg; filenames match cfgspec for FCS kinds", function()
  local cfgspec = require("fcs.io.cfgspec")
  t.eq(#M.KINDS, 4)
  t.eq(M.FILE.devbind, cfgspec.FILES.devbind)
  t.eq(M.FILE.uicfg, "eh2_ui_config.tbl")
end)
t.test("validateKind uses cfgspec for FCS kinds and table-shape for uicfg", function()
  t.eq(M.validateKind("uicfg", {}), true)
  t.eq(M.validateKind("uicfg", nil), false)
  t.eq(M.validateKind("devbind", { thrusters = {}, sensors = {} }), true)
  t.eq(M.validateKind("devbind", { thrusters = {} }), false)  -- missing sensors
end)
```
(Use the file's existing `M` require-local.)

- [ ] **Step 2: Run — expect RED.**

- [ ] **Step 3: Implement** — in `ui/basalt/bitconfig/dtc.lua`: add `local cfgspec = require("fcs.io.cfgspec")` if not present; define `M.KINDS`/`M.FILE`/`M.LABEL`/`M.validateKind` as above; change `M.localPath(kind)` → `"/" .. M.FILE[kind]` and `M.diskPath(mount, kind)` → `"/" .. mount .. "/" .. M.FILE[kind]`. Update `M.plan` to iterate the new `M.KINDS` and use `M.FILE`/`M.LABEL`. Keep every existing FCS-kind path byte-identical (so `tests/test_bitconfig_dtc.lua`'s `diskPath`↔`loaderui.diskSource` match still passes).

- [ ] **Step 4: Run — expect GREEN.**

- [ ] **Step 5: Commit** — `git add ui/basalt/bitconfig/dtc.lua tests/test_bitconfig_dtc.lua && git commit`.

### Task 10: DTC row model — timestamps + newer/older/missing

**Files:** Modify `ui/basalt/bitconfig/dtc.lua` (add pure row/timestamp helpers); Modify `tests/test_bitconfig_dtc.lua`.

**Interfaces:**
- Produces:
  - `M.fmtTime(msEpoch) -> string` — `os.date("%Y-%m-%d %H:%M", math.floor(msEpoch/1000))`; nil → `"--"`.
  - `M.row(kind, info) -> { kind, label, localHas, localMs, diskHas, diskMs, diskValid, rel }` where `info = { localHas, localMs, diskHas, diskMs, diskValid }` and `rel` ∈ `"newer"|"older"|"same"|"local-only"|"disk-only"|"none"` comparing local vs disk mtime (local perspective: `newer` = local newer than disk). PURE.

- [ ] **Step 1: Write the failing test** — append:
```lua
t.test("fmtTime formats ms epoch and handles nil", function()
  t.eq(M.fmtTime(nil), "--")
  t.truthy(#M.fmtTime(1000000000000) >= 10, "formatted")
end)
t.test("row computes the local-vs-disk relation", function()
  t.eq(M.row("tuning", { localHas=true, localMs=200, diskHas=true, diskMs=100, diskValid=true }).rel, "newer")
  t.eq(M.row("tuning", { localHas=true, localMs=100, diskHas=true, diskMs=200, diskValid=true }).rel, "older")
  t.eq(M.row("tuning", { localHas=true, diskHas=false }).rel, "local-only")
  t.eq(M.row("tuning", { localHas=false, diskHas=true, diskValid=true }).rel, "disk-only")
  t.eq(M.row("tuning", { localHas=false, diskHas=false }).rel, "none")
end)
```

- [ ] **Step 2: Run — expect RED.**

- [ ] **Step 3: Implement** — add `M.fmtTime` and `M.row` per the interface. `rel`: if both present compare ms (`newer`/`older`/`same`, treat missing ms as 0); local-only / disk-only / none otherwise.

- [ ] **Step 4: Run — expect GREEN.**

- [ ] **Step 5: Commit.**

### Task 11: DTC per-kind IO + backup-before-import

**Files:** Modify `ui/basalt/bitconfig/dtc.lua` (`_scan` gains mtime+validity; add `M._exportKind`/`M._importKind`); Modify `tests/test_bitconfig_dtc.lua`.

**Interfaces:**
- Consumes: injected `deps` = `{ exists, read, write, delete, move, attributes, backup }` (all defaulted to real fs; `attributes(path)->{modified}|nil`; `backup(path)` = `Suite.backupConfig` on the UI PC).
- Produces:
  - `M._scanKind(mount, kind, deps) -> { localHas, localMs, diskHas, diskMs, diskValid }` — stats local + disk file, reads+validates the disk file via `M.validateKind`.
  - `M._exportKind(mount, kind, deps) -> ok` — atomic local→disk copy of one kind (local must exist).
  - `M._importKind(mount, kind, deps) -> ok` — `deps.backup(localPath)` FIRST, then atomic disk→local copy of one kind (disk must exist + be valid).

- [ ] **Step 1: Write the failing test** — append (drive with injected in-memory `deps`; mirror the file's existing injected-deps tests):
```lua
t.test("_importKind backs up the local file before overwriting it", function()
  local store = { ["/disk/eh2_tuning.tbl"] = "NEW", ["/eh2_tuning.tbl"] = "OLD" }
  local backedUp = {}
  local deps = {
    exists = function(p) return store[p] ~= nil end,
    read = function(p) return store[p] end,
    write = function(p, b) store[p] = b end,   -- atomic write shim
    delete = function(p) store[p] = nil end,
    move = function(a,b) store[b] = store[a]; store[a] = nil end,
    attributes = function(p) return store[p] and { modified = 1 } or nil end,
    backup = function(p) backedUp[#backedUp+1] = p end,
    validate = nil,
  }
  local ok = M._importKind("disk", "tuning", deps)
  t.eq(ok, true)
  t.eq(store["/eh2_tuning.tbl"], "NEW", "local overwritten from disk")
  t.eq(backedUp[1], "/eh2_tuning.tbl", "local backed up before overwrite")
end)
t.test("_exportKind copies local to disk", function()
  local store = { ["/eh2_tuning.tbl"] = "L" }
  local deps = { exists=function(p) return store[p]~=nil end, read=function(p) return store[p] end,
    write=function(p,b) store[p]=b end, delete=function(p) store[p]=nil end, move=function(a,b) store[b]=store[a]; store[a]=nil end }
  t.eq(M._exportKind("disk", "tuning", deps), true)
  t.eq(store["/disk/eh2_tuning.tbl"], "L")
end)
```
(Match the file's actual atomicCopy/deps signatures — read `M._export`/`M._import`/`atomicCopy` first and reuse the same `write/exists/delete/move` seam so these behave like the existing bulk copiers.)

- [ ] **Step 2: Run — expect RED.**

- [ ] **Step 3: Implement** — factor the existing `atomicCopy` to a single-kind copy; `M._exportKind`/`M._importKind` copy one kind's `localPath`↔`diskPath`; `_importKind` calls `deps.backup(M.localPath(kind))` before the copy (guard: only if the local file exists). `M._scanKind` uses `deps.attributes(path).modified` for mtimes and `M.validateKind(kind, unserialise(read(diskPath)))` for `diskValid`. Keep the existing bulk `_export/_import/_scan` working (or re-express them over the per-kind fns).

- [ ] **Step 4: Run — expect GREEN.**

- [ ] **Step 5: Commit.**

### Task 12: DTC UI — two drilldowns, confirmations, disk summary

**Files:** Modify `ui/basalt/bitconfig/dtc.lua` (`M.build`); Modify `tests/test_bitconfig_dtc.lua` (construction probe + a pure `_select`-style seam test).

**Interfaces:** Produces: `M.build(basalt, frame, runtime, nav, deps)` returns `{ id, apply, elements }` (same contract as today). Top screen: `EXPORT (UI PC -> disk)`, `IMPORT (disk -> UI PC)`, `REFRESH` buttons + a disk summary label ("disk: <label> · valid N/4" or "no disk"). EXPORT/IMPORT push a Region drilldown listing the 4 kinds (each row: label · local time · disk time · validity · rel-indicator via `M.row`/`M.fmtTime`); selecting a row runs a confirm then `M._exportKind`/`M._importKind` and refreshes. A pure `M._confirmText(dir, kind) -> string` seam is unit-tested.

- [ ] **Step 1: Study the templates** — read `ui/basalt/bitconfig/senscal.lua` (or `senssource.lua`) for the `ui.basalt.region` drilldown + `configkit.actionRow` pattern, and read how `senscal`/`mdb` implement a save-confirm (the reusable confirm step). Reuse that confirm pattern for the per-row action.

- [ ] **Step 2: Write the failing test** — append to `tests/test_bitconfig_dtc.lua`:
```lua
t.test("_confirmText names the direction and file", function()
  local e = M._confirmText("export", "tuning")
  t.truthy(e:find("disk", 1, true), "export mentions disk")
  local i = M._confirmText("import", "tuning")
  t.truthy(i:find("UI", 1, true) or i:find("local", 1, true), "import mentions local/UI")
end)
```
Plus a construction probe mirroring the existing dtc build test (build a Basalt frame headless, call `M.build(...)`, `apply({})`, one `basalt.update("timer", -1)`, assert no error). Add `M._confirmText(dir, kind)` returning e.g. `"Overwrite "..M.FILE[kind].." on the disk?"` (export) / `"Overwrite "..M.FILE[kind].." on this UI PC?"` (import).

- [ ] **Step 3: Run — expect RED** (`M._confirmText` missing).

- [ ] **Step 4: Implement** — rebuild `M.build`: top screen with the three directional buttons + disk summary (from `M._detect` + counting `diskValid` across `M._scanKind`); two Region drilldown screens ("export"/"import") each rendering 4 rows via `M.row`/`M.fmtTime`; row click → confirm (reused pattern) → `M._exportKind`/`M._importKind` → refresh + status line. Import rows disabled unless `diskHas and diskValid`. Keep load-purity (all fs/peripheral behind `deps`/closures) and the injected-deps seam.

- [ ] **Step 5: Run — expect GREEN.**

- [ ] **Step 6: Commit.**

---

## Phase 3 — Confirmations (boot loader)

### Task 13: FCS boot confirm for disk/ui sources

**Files:** Modify `fcs/boot/loaderui.lua`; Test: extend `tests/test_bootloaderui.lua` (or the bootloader test) for the pure decision.

**Interfaces:** Produces: `M.needsConfirm(src) -> bool` (true for `"disk"`/`"ui"`, false for `"own"`/`"defaults"`); the interactive `pickUntilValid`/`run` flow prompts a Y/N confirm after a `needsConfirm` source is picked, re-picking on N.

- [ ] **Step 1: Write the failing test** — append to `tests/test_bootloaderui.lua`:
```lua
t.test("needsConfirm is true only for external sources", function()
  t.eq(M.needsConfirm("disk"), true)
  t.eq(M.needsConfirm("ui"), true)
  t.eq(M.needsConfirm("own"), false)
  t.eq(M.needsConfirm("defaults"), false)
end)
```
(Match the file's require-local for `fcs.boot.loaderui`.)

- [ ] **Step 2: Run — expect RED.**

- [ ] **Step 3: Implement** — add to `fcs/boot/loaderui.lua`:
```lua
function M.needsConfirm(src) return src == "disk" or src == "ui" end
```
Then in the in-game pick flow (`pickUntilValid`/`run`, in-game only), after a valid non-ABORT source is chosen, if `M.needsConfirm(src)` prompt `"<CONCERN> from <src> will overwrite the FCS runtime config -- proceed? (Y/N): "`; on N, re-pick that concern. (`own`/`defaults` proceed silently.)

- [ ] **Step 4: Run — expect GREEN.**

- [ ] **Step 5: Commit** — `git add fcs/boot/loaderui.lua tests/test_bootloaderui.lua && git commit`.

---

## Task 14: Dist build + full acceptance gates

**Files:** Modify `tests/run_headless_dist.sh` (register new suites); Build outputs `dist/**`, `manifest.lua`, `manifest-dev.lua`.

- [ ] **Step 1: Register new suites in the dist array** — append to `tests/run_headless_dist.sh` every NEW test-file suite created in this batch: at minimum `"tests.test_splitconfig"` (plus any other NEW `tests/test_*` file added; suites merely EXTENDED, like `test_bitconfig_dtc`/`test_suite`/`test_manifest_tools`, are already registered).

- [ ] **Step 2: Build + regen** — `node tools/build.mjs && bash tools/run_gen.sh`.

- [ ] **Step 3: Verify IN SYNC** — `bash tools/run_gen.sh --check` → exit 0.

- [ ] **Step 4: Run all three gates:**
```bash
bash tests/run_headless.sh        # source -> OK
bash tests/run_headless_dist.sh   # minified dist -> OK (count tracks source)
bash tests/run_suite_e2e.sh       # e2e -> pass
```

- [ ] **Step 5: Commit** — `git add tests/run_headless_dist.sh dist manifest.lua manifest-dev.lua && git commit`.

---

## Post-implementation (batch ship)

- Whole-branch review (superpowers:requesting-code-review), most-capable model.
- ff-merge to `main` → `git push origin main`.
- **In-world (user, test pilot):**
  1. Install the `splitconfig` tool on the FCS via the SuiteX Advanced tab, then run `splitconfig` on the FCS console → confirm it writes `eh2_devbind.tbl` + `eh2_senscal.tbl`, leaves `eh2_hw_config.tbl` intact, and reports OK. Reboot the FCS and confirm flight is unchanged (own source now reads the split files).
  2. Update the ui role; open BIT/CONFIG → DTC; insert a disk; REFRESH → confirm the 4-row overview with disk/local timestamps + validity; EXPORT each file to the disk (confirm prompts), then IMPORT one back (confirm + local backup) and verify feedback.
  3. On an FCS boot, pick a `disk`/`ui` source for a concern → confirm the new Y/N prompt appears; pick `own`/`defaults` → no prompt.
  4. Run the Suite on both PCs → confirm `/easyhover2_backup` now holds all 4 files (latest copy each).

## Self-Review notes (author)

- **Spec coverage:** separation invariant ✓ (T5 probe, T6 fix_yaw_sign; calibrate/binddevices/UI already split), split migration ✓ (T1-T4), backups single-latest-per-file + expanded sets ✓ (T7-T8), DTC 4-kind registry + uicfg ✓ (T9), timestamps + rel ✓ (T10), per-file IO + backup-before-import ✓ (T11), DTC UI drilldowns + confirms + disk summary ✓ (T12), boot confirm ✓ (T13), gates ✓ (T14). Fused runtime file untouched; frozen flight code untouched.
- **Type consistency:** cfgspec API (`load/save/merge/validate/splitLegacy/FILES`) used identically across T1/T5/T6/T9; DTC `M.FILE`/`M.validateKind`/`M.row`/`M.fmtTime`/`M._scanKind`/`M._exportKind`/`M._importKind` produced in T9-T11 and consumed in T12; `Suite.backupConfig` per-file (T7) consumed by DTC import (T11) + role sets (T8).
- **Open risks for the implementer:** confirm `probe.lua` has no branch that WRITES the fused file other than bind (leave read-only legacy reads alone); match each test file's existing require-local + injected-deps seam (T7/T11 especially — read `atomicCopy` before refactoring); keep the 3 FCS DTC paths byte-identical to `cfgspec.FILES` so the `loaderui.diskSource` path-match test holds; `fs.attributes().modified` is ms (÷1000 for `os.date`).
